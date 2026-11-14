using System.Security.Cryptography;
using System.Text;
using Dapper;
using Microsoft.Data.Sqlite;

record Book(string Id, string Title, string Author, string Origin, string Url, string Intro, string Cover, long Shelf, long Updated);
record Entry(string Id, string BookId, string Title, long Ord, string Url, string Body);
record Block(string Text, string Kind = "p", string? Image = null, string? Markup = null, string? CommentCount=null,string? CommentUrl=null,string? CommentText=null);
record Spot(string BookId, string ChapterId, long Paragraph, long Offset, string Quote, long Version, long Updated);
record Reading(string ChapterId, int Paragraph, int Offset, string Quote, long Version, string EventId);
record Source(string Id, string Name, string GroupName, long Enabled, string Issue, string Raw);
record Asset(byte[] Data, string Mime);
record Parsed(string Title, string Author, List<(string Title, List<Block> Blocks)> Chapters, Dictionary<string, Asset> Assets);
class Library
{
    public readonly string Root;
    readonly string connection;
    public Library(string root)
    {
        Root = Path.GetFullPath(root);
        Directory.CreateDirectory(Path.Combine(Root, "originals"));
        connection = new SqliteConnectionStringBuilder { DataSource = Path.Combine(Root, "library.sqlite"), ForeignKeys = true, DefaultTimeout = 20 }.ToString();
        using var db = Open();
        db.Execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sources(Id TEXT PRIMARY KEY,Name TEXT,GroupName TEXT,Enabled INTEGER,Issue TEXT,Raw TEXT);
        CREATE TABLE IF NOT EXISTS books(Id TEXT PRIMARY KEY,Title TEXT,Author TEXT,Origin TEXT,Url TEXT,Intro TEXT,Cover TEXT,Shelf INTEGER,Updated INTEGER);
        CREATE TABLE IF NOT EXISTS chapters(Id TEXT PRIMARY KEY,BookId TEXT REFERENCES books ON DELETE CASCADE,Title TEXT,Ord INTEGER,Url TEXT,Body TEXT);
        CREATE INDEX IF NOT EXISTS ix_chapters ON chapters(BookId,Ord);
        CREATE TABLE IF NOT EXISTS assets(BookId TEXT REFERENCES books ON DELETE CASCADE,Id TEXT,Data BLOB,Mime TEXT,PRIMARY KEY(BookId,Id));
        CREATE TABLE IF NOT EXISTS covers(BookId TEXT PRIMARY KEY REFERENCES books ON DELETE CASCADE,Source TEXT NOT NULL,Data BLOB,Mime TEXT,RetryAt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS progress(BookId TEXT PRIMARY KEY REFERENCES books ON DELETE CASCADE,ChapterId TEXT,Paragraph INTEGER,Offset INTEGER,Quote TEXT,Version INTEGER,Updated INTEGER);
        CREATE TABLE IF NOT EXISTS history(Id TEXT PRIMARY KEY,BookId TEXT REFERENCES books ON DELETE CASCADE,ChapterId TEXT,Version INTEGER,Updated INTEGER);
        """);
    }
    public SqliteConnection Open() { var db = new SqliteConnection(connection); db.Open(); return db; }
    public static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public static string Key(string input) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(input)))[..32];
    public static string Json<T>(T value) => System.Text.Json.JsonSerializer.Serialize(value, new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web));
    public Book Get(string id) { using var db = Open(); return db.QuerySingleOrDefault<Book>("SELECT * FROM books WHERE Id=@id", new { id }) ?? throw new KeyNotFoundException("书籍不存在"); }
    public Source Source(string id) { using var db = Open(); return db.QuerySingleOrDefault<Source>("SELECT * FROM sources WHERE Id=@id", new { id }) ?? throw new KeyNotFoundException("书源已删除"); }
    public Spot? Position(string id) { using var db = Open(); return db.QuerySingleOrDefault<Spot>("SELECT * FROM progress WHERE BookId=@id", new { id }); }
    public IResult Save(string id, Reading r)
    {
        if (r.Paragraph < 0 || r.Offset < 0 || !Guid.TryParse(r.EventId, out _) || r.Quote.Length > 512) throw new InvalidDataException("阅读位置无效");
        using var db = Open(); using var tx = db.BeginTransaction(deferred: false);
        if (db.ExecuteScalar<int>("SELECT count(*) FROM chapters WHERE Id=@ChapterId AND BookId=@id", new { id, r.ChapterId }, tx) == 0) throw new KeyNotFoundException("章节不存在");
        var old = db.QuerySingleOrDefault<Spot>("SELECT * FROM progress WHERE BookId=@id", new { id }, tx);
        var accepted = db.QuerySingleOrDefault<long?>("SELECT Version FROM history WHERE Id=@EventId AND BookId=@id", new { id, r.EventId }, tx);
        if (accepted != null) return Results.Ok(new { version = accepted, updated = old?.Updated });
        if ((old?.Version ?? 0) != r.Version) return Results.Conflict(old);
        var spot = new Spot(id, r.ChapterId, r.Paragraph, r.Offset, r.Quote, r.Version + 1, Now);
        db.Execute("INSERT OR REPLACE INTO progress VALUES(@BookId,@ChapterId,@Paragraph,@Offset,@Quote,@Version,@Updated)", spot, tx);
        db.Execute("INSERT INTO history VALUES(@EventId,@id,@ChapterId,@Version,@Updated)", new { r.EventId, id, r.ChapterId, spot.Version, spot.Updated }, tx);
        db.Execute("UPDATE books SET Updated=@Updated WHERE Id=@id", new { id, spot.Updated }, tx); tx.Commit(); return Results.Ok(spot);
    }
    public void SaveSearch(Book book)
    {
        using var db = Open();
        db.Execute("""INSERT INTO books VALUES(@Id,@Title,@Author,@Origin,@Url,@Intro,@Cover,0,0) ON CONFLICT(Id) DO UPDATE SET Title=excluded.Title,Author=excluded.Author,Intro=excluded.Intro,Cover=coalesce(nullif(excluded.Cover,''),books.Cover)""", book);
    }
    public List<object> Toc(string id) { using var db = Open(); return db.Query("SELECT Id as id,Title as title,Ord as ord FROM chapters WHERE BookId=@id ORDER BY Ord", new { id }).Select(row => (object)new { id = (string)row.id, title = (string)row.title, ord = (long)row.ord }).ToList(); }
    public void ReplaceToc(string id, List<Entry> entries)
    {
        using var db = Open(); using var tx = db.BeginTransaction();
        db.Execute("DELETE FROM chapters WHERE BookId=@id", new { id }, tx);
        db.Execute("INSERT INTO chapters VALUES(@Id,@BookId,@Title,@Ord,@Url,@Body)", entries, tx); tx.Commit();
    }
    public async Task<Book> Import(Stream stream, string filename, string? encoding)
    {
        var ext = Path.GetExtension(filename).ToLowerInvariant();
        if (ext is not (".txt" or ".epub")) throw new InvalidDataException("请选择 TXT 或 EPUB");
        var temp = Path.Combine(Root, "originals", Guid.NewGuid() + ".tmp");
        try
        {
            await using (var output = File.Create(temp)) await stream.CopyToAsync(output);
            string id; await using (var file = File.OpenRead(temp)) id = Convert.ToHexStringLower(await SHA256.HashDataAsync(file));
            using var db = Open();
            var existing = db.QuerySingleOrDefault<Book>("SELECT * FROM books WHERE Id=@id", new { id });
            if (existing != null) { db.Execute("UPDATE books SET Shelf=1 WHERE Id=@id", new { id }); return existing with { Shelf = 1 }; }
            var parsed = ext == ".txt" ? Ebooks.Txt(await File.ReadAllBytesAsync(temp), filename, encoding) : Ebooks.Epub(temp, filename);
            if (parsed.Chapters.Count == 0) throw new InvalidDataException("未找到可阅读的章节");
            using var tx = db.BeginTransaction(deferred: false);
            var book = new Book(id, parsed.Title, parsed.Author, "local", ext, "", "", 1, Now);
            var added = db.Execute("INSERT OR IGNORE INTO books VALUES(@Id,@Title,@Author,@Origin,@Url,@Intro,@Cover,@Shelf,@Updated)", book, tx);
            if (added == 1)
            {
                for (int i = 0; i < parsed.Chapters.Count; i++)
                {
                    var chapter = parsed.Chapters[i]; var entry = new Entry(Key(id + "/" + i), id, chapter.Title, i, "", Json(chapter.Blocks));
                    db.Execute("INSERT INTO chapters VALUES(@Id,@BookId,@Title,@Ord,@Url,@Body)", entry, tx);
                }
                foreach (var (key, asset) in parsed.Assets) db.Execute("INSERT INTO assets VALUES(@id,@key,@Data,@Mime)", new { id, key, asset.Data, asset.Mime }, tx);
                File.Move(temp, Path.Combine(Root, "originals", id + ext), true);
            }
            else db.Execute("UPDATE books SET Shelf=1 WHERE Id=@id", new { id }, tx);
            tx.Commit(); return Get(id);
        }
        finally { File.Delete(temp); }
    }
    public void DeleteLocal(string id)
    {
        using var db = Open(); using var tx = db.BeginTransaction(deferred: false);
        var book = db.QuerySingleOrDefault<Book>("SELECT * FROM books WHERE Id=@id AND Origin='local'", new { id }, tx) ?? throw new KeyNotFoundException("电子书不存在");
        db.Execute("DELETE FROM books WHERE Id=@id", new { id }, tx);
        File.Delete(Path.Combine(Root, "originals", book.Id + book.Url)); tx.Commit();
    }
}
