using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Dapper;
using Microsoft.AspNetCore.Http.Features;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
var builder = WebApplication.CreateBuilder(args);
var root = Environment.GetEnvironmentVariable("NOVEL_DATA") ?? Path.Combine(AppContext.BaseDirectory, "data");
var library = new Library(root); var catalog = new Catalog(library);
var keyFile = Path.Combine(library.Root, "access-token.txt");
var token = Environment.GetEnvironmentVariable("NOVEL_TOKEN");
if (string.IsNullOrWhiteSpace(token))
{
    if (!File.Exists(keyFile)) File.WriteAllText(keyFile, Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24)));
    token = File.ReadAllText(keyFile).Trim();
}
if (token.Length == 0) throw new InvalidOperationException("个人令牌不能为空");
builder.WebHost.UseUrls(Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://127.0.0.1:7186");
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 130L * 1024 * 1024);
builder.Services.Configure<FormOptions>(o => o.MultipartBodyLengthLimit = 128L * 1024 * 1024);
var app = builder.Build(); var auth = SHA256.HashData(Encoding.UTF8.GetBytes("Bearer " + token));
Console.WriteLine("个人书房 · 服务数据目录 " + library.Root);
Console.WriteLine("个人令牌文件 " + keyFile + "（设置 NOVEL_TOKEN 时使用环境变量）");
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path != "/health" && !CryptographicOperations.FixedTimeEquals(auth, SHA256.HashData(Encoding.UTF8.GetBytes(ctx.Request.Headers.Authorization.ToString())))) { ctx.Response.StatusCode = 401; await ctx.Response.WriteAsJsonAsync(new { error = "个人令牌不正确" }); return; }
    try { await next(); }
    catch (Exception e) when (!ctx.Response.HasStarted)
    {
        ctx.Response.StatusCode = e switch { KeyNotFoundException => 404, NotSupportedException => 422, HttpRequestException => 502, OperationCanceledException => 504, _ => 400 };
        await ctx.Response.WriteAsJsonAsync(new { error = e.Message });
    }
});
ReaderTools.Map(app,library,catalog);
ReadingTime.Map(app, library);
var covers = new BookCovers(library);
app.MapGet("/api/books/{id}/cover", async (string id, CancellationToken ct) =>
{
    var cover = await covers.Get(id, ct);
    return cover is null ? Results.NoContent() : Results.File(cover.Data, cover.Mime);
});
app.MapGet("/health", () => new { app = "个人书房", version = 2 });
app.MapGet("/api/library", () =>
{
    using var db = library.Open();
    var indicators = db.Query("""
        WITH editions AS (
            SELECT b.Id, coalesce((SELECT json_extract(Data,'$.targetBook') FROM reader_items
                WHERE Kind='mapping' AND BookId=b.Id AND json_extract(Data,'$.chapter')='*'
                ORDER BY Updated DESC LIMIT 1), b.Id) AS edition FROM books b
            WHERE b.Shelf=1 OR b.Id IN (SELECT BookId FROM progress)
        )
        SELECT s.Id as id, p.ChapterId as chapterId, c.Title as current, p.Updated as stamp,
            (SELECT Title FROM chapters WHERE BookId=s.edition ORDER BY Ord DESC LIMIT 1) as latest,
            (SELECT count(*) FROM chapters WHERE BookId=s.edition) as total,
            CASE WHEN c.BookId=s.edition THEN c.Ord ELSE (
                SELECT Ord FROM chapters WHERE BookId=s.edition AND trim(Title)=trim(c.Title) LIMIT 1
            ) END as ord
        FROM editions s LEFT JOIN progress p ON p.BookId=s.Id LEFT JOIN chapters c ON c.Id=p.ChapterId
        """);
    return new { indicators, shelf = db.Query<Book>("SELECT * FROM books WHERE Shelf=1 ORDER BY Updated DESC,Title"), history = db.Query<Book>("SELECT b.* FROM books b JOIN progress p ON p.BookId=b.Id ORDER BY p.Updated DESC") };
});
app.MapGet("/api/sources", () =>
{
    using var db = library.Open();
    return db.Query("""
        SELECT Id AS id, Name AS name, GroupName AS groupName, Enabled AS enabled, Issue AS issue, '' AS raw
        FROM sources ORDER BY Name
        """);
});
app.MapGet("/api/sources/{id}", (string id) => library.Source(id));
app.MapPost("/api/sources/import", async (JsonElement data, CancellationToken ct) =>
{
    string json = data.TryGetProperty("url", out var url) ? (await Remote.Fetch(url.GetString()!, url.GetString()!, ct: ct)).Body : data.GetProperty("json").GetString()!;
    return catalog.Import(json);
});
app.MapPut("/api/sources/{id}", (string id, JsonElement data) => catalog.Import(data.GetProperty("json").GetString()!, id));
app.MapPut("/api/sources/{id}/enabled", (string id, JsonElement data) => { using var db = library.Open(); return db.Execute("UPDATE sources SET Enabled=@enabled WHERE Id=@id", new { id, enabled = data.GetProperty("enabled").GetBoolean() ? 1 : 0 }); });
app.MapDelete("/api/sources/{id}", (string id) => { using var db = library.Open(); return db.Execute("DELETE FROM sources WHERE Id=@id", new { id }); });
app.MapGet("/api/search", (string source, string q, CancellationToken ct) => catalog.Search(source, q, ct));
app.MapGet("/api/tomato", () => new { available = false, reason = "番茄暂不可用：尚无验证通过的搜索与单章中文正文通道。" });
app.MapGet("/api/books/{id}", (string id) => library.Get(id));
app.MapPut("/api/books/{id}/shelf", (string id, JsonElement data) => { using var db = library.Open(); return db.Execute("UPDATE books SET Shelf=@shelf WHERE Id=@id", new { id, shelf = data.GetProperty("shelf").GetBoolean() ? 1 : 0 }); });
app.MapGet("/api/books/{id}/toc", (string id, bool? refresh, CancellationToken ct) => catalog.Contents(library.Get(id), refresh == true, ct));
app.MapGet("/api/books/{id}/chapters/{chapter}", (string id, string chapter, CancellationToken ct) => catalog.Chapter(id, chapter, ct));
app.MapGet("/api/books/{id}/progress", (string id) => Results.Json(library.Position(id)));
app.MapPut("/api/books/{id}/progress", (string id, Reading reading) => library.Save(id, reading));
app.MapGet("/api/books/{id}/chapters/{chapter}/url",(string id,string chapter)=>{ using var db=library.Open();return new {url=db.ExecuteScalar<string>("SELECT Url FROM chapters WHERE BookId=@id AND Id=@chapter",new{id,chapter})};});
app.MapGet("/api/books/{id}/assets/{asset}", (string id, string asset) => { using var db = library.Open(); var image = db.QuerySingleOrDefault<Asset>("SELECT Data,Mime FROM assets WHERE BookId=@id AND Id=@asset", new { id, asset }); return image == null ? Results.NotFound() : Results.File(image.Data, image.Mime); });
app.MapDelete("/api/books/{id}", (string id) => { library.DeleteLocal(id); return Results.Ok(); });
app.MapPost("/api/preview", (JsonElement data) => new { text = Ebooks.Decode(Convert.FromBase64String(data.GetProperty("bytes").GetString()!), data.GetProperty("encoding").GetString()) });
app.MapPost("/api/upload", async (HttpRequest req) =>
{
    var form = await req.ReadFormAsync(); var file = form.Files.GetFile("file") ?? throw new InvalidDataException("缺少文件");
    using var stream = file.OpenReadStream(); return await library.Import(stream, Path.GetFileName(file.FileName), form["encoding"]);
});
app.Run();
