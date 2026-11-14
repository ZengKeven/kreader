using System.Text.Json;
using Dapper;

static class ReaderTools
{
    public static void Map(WebApplication app, Library lib, Catalog catalog)
    {
        using (var db = lib.Open()) {
            using var tx=db.BeginTransaction();
            if (db.ExecuteScalar<int>("PRAGMA user_version",transaction:tx)>2) throw new InvalidOperationException("数据库来自更新版本");
            db.Execute("""
                CREATE TABLE IF NOT EXISTS reader_items (
                    Kind TEXT NOT NULL, Id TEXT NOT NULL, BookId TEXT REFERENCES books ON DELETE CASCADE,
                    Data TEXT NOT NULL, Updated INTEGER NOT NULL, PRIMARY KEY(Kind,Id));
                CREATE INDEX IF NOT EXISTS ix_items_book ON reader_items(Kind,BookId);
                PRAGMA user_version=2;
                """,transaction:tx);
            tx.Commit();
        }
        string Kind(string kind) => kind is "mark" or "group" or "membership" or "rule" or "dict" or "correction" or "mapping" ? kind : throw new InvalidDataException("未知数据类型");
        app.MapGet("/api/items/{kind}",(string kind,string? book) => {
            using var db=lib.Open();
            return db.Query<string>("SELECT Data FROM reader_items WHERE Kind=@k AND (@book IS NULL OR BookId=@book) ORDER BY Updated DESC", new {k=Kind(kind),book}).Select(s=>JsonSerializer.Deserialize<JsonElement>(s));
        });
        app.MapPut("/api/items/{kind}/{id}",(string kind,string id,JsonElement item)=>{
            Kind(kind); if(id.Length>160 || item.GetProperty("id").GetString()!=id || item.GetRawText().Length>65536) throw new InvalidDataException("记录无效");
            string? book=item.TryGetProperty("book",out var b)?b.GetString():null;
            if ((kind is "mark" or "membership" or "mapping" or "correction") && book==null) throw new InvalidDataException("缺少书籍");
            using var db=lib.Open(); db.Execute("INSERT INTO reader_items VALUES(@kind,@id,@book,@data,@t) ON CONFLICT(Kind,Id) DO UPDATE SET BookId=excluded.BookId, Data=excluded.Data,Updated=excluded.Updated",new {kind,id,book,data=item.GetRawText(),t=Library.Now}); return Results.Ok(item);
        });
        app.MapDelete("/api/items/{kind}/{id}",(string kind,string id)=>{
            using var db=lib.Open();return db.Execute("DELETE FROM reader_items WHERE Kind=@k AND Id=@id",new {k=Kind(kind),id});});
        app.MapGet("/api/dictionary/lookup",async(string rule,string q,CancellationToken ct)=>{
            using var db=lib.Open();
            var data=db.ExecuteScalar<string>("SELECT Data FROM reader_items WHERE Kind='dict' AND Id=@rule",new{rule})??throw new KeyNotFoundException("词典规则不存在");
            var r=JsonSerializer.Deserialize<JsonElement>(data);var url=r.GetProperty("url").GetString()!.Replace("{word}",Uri.EscapeDataString(q));
            if(!Uri.TryCreate(url,UriKind.Absolute,out var addr)||addr.Scheme is not ("http" or "https"))throw new InvalidDataException("词典地址无效");
            var page=await Remote.Fetch(url,url,ct:ct);var definition=Rules.Text(Rules.Document(page.Body),r.GetProperty("selector").GetString()!);
            if(string.IsNullOrWhiteSpace(definition))throw new InvalidDataException("词典没有返回释义");
            return new {text=definition[..Math.Min(definition.Length,10000)]};
        });
        app.MapGet("/api/books/{id}/chapters/{chapter}/comments",async(string id,string chapter,int paragraph,CancellationToken ct)=>{
            var item=JsonSerializer.Deserialize<JsonElement>(Library.Json(await catalog.Chapter(id,chapter,ct)));
            var blocks=item.GetProperty("blocks");if(paragraph<0||paragraph>=blocks.GetArrayLength())throw new InvalidDataException("段落不存在");
            var b=blocks[paragraph];var text=b.TryGetProperty("commentText",out var t)?t.GetString():null;var url=b.TryGetProperty("commentUrl",out var u)?u.GetString():null;
            if(string.IsNullOrWhiteSpace(text)&&!string.IsNullOrWhiteSpace(url)){var page=await Remote.Fetch(url,url,ct:ct);text=Rules.Plain(page.Body);}
            return new{text=string.IsNullOrWhiteSpace(text)?"书源只提供了段评数量。":text[..Math.Min(text.Length,16000)],url};
        });
        app.MapGet("/api/activity",()=>{
            using var db=lib.Open();return db.Query("""
            SELECT b.Id as book,b.Title as title,c.Title as chapter,h.ChapterId as chapterId,
            date(h.Updated/1000,'unixepoch','localtime') as day,max(h.Updated) as last
            FROM history h JOIN books b ON h.BookId=b.Id LEFT JOIN chapters c ON c.Id=h.ChapterId
            GROUP BY day,h.BookId,h.ChapterId ORDER BY last DESC LIMIT 2000
            """);});
        app.MapGet("/api/books/{id}/find",(string id,string q)=>{
            if(q.Trim().Length==0)throw new InvalidDataException("请输入关键词");
            if(lib.Get(id).Origin!="local")throw new InvalidDataException("在线小说请搜索本机缓存");
            using var db=lib.Open();return db.Query("""
            SELECT c.Id as chapterId,c.Title as title,cast(j.key as integer) as paragraph,
            json_extract(j.value,'$.text') as text FROM chapters c,json_each(c.Body) j
            WHERE c.BookId=@id AND instr(json_extract(j.value,'$.text'),@q)>0 ORDER BY c.Ord,cast(j.key as integer) LIMIT 300
            """,new{id,q}).Select(r=>new {chapterId=(string)r.chapterId,title=(string)r.title,paragraph=(long)r.paragraph,offset=((string)r.text).IndexOf(q,StringComparison.Ordinal), text=(string)r.text});});
        app.MapPost("/api/books/{id}/reparse",(string id,ParseOptions opt)=>{
            var book=lib.Get(id);if(book.Origin!="local"||book.Url!=".txt")throw new InvalidDataException("仅支持 TXT");
            var parsed=Ebooks.Txt(File.ReadAllBytes(Path.Combine(lib.Root,"originals",id+".txt")),book.Title+".txt",opt.Encoding,opt.Pattern);
            if(parsed.Chapters.Count==0)throw new InvalidDataException("未找到章节");
            // Content-derived chapter keys avoid silently reusing an old ordinal for different text.
            var entries=parsed.Chapters.Select((c,i)=>new Entry(Library.Key(id+"/"+i+"/"+c.Title),id,c.Title,i,"",Library.Json(c.Blocks))).ToList();
            using var db=lib.Open();using var tx=db.BeginTransaction(deferred:false);
            db.Execute("DELETE FROM chapters WHERE BookId=@id",new{id},tx);db.Execute("INSERT INTO chapters VALUES(@Id,@BookId,@Title,@Ord,@Url,@Body)",entries,tx);
            var old=db.QuerySingleOrDefault<Spot>("SELECT * FROM progress WHERE BookId=@id",new{id},tx);
            if(old!=null && old.Quote.Length>0){
                var matches=parsed.Chapters.SelectMany((c,i)=>c.Blocks.SelectMany((b,p)=>Occurrences(b.Text,old.Quote).Select(o=>(i,p,o)))).Take(2).ToList();
                if(matches.Count==1){var m=matches[0];db.Execute("UPDATE progress SET ChapterId=@ch,Paragraph=@p,Offset=@o,Version=Version+1 WHERE BookId=@id",new{id,ch=entries[m.i].Id,m.p,m.o},tx);}
            }
            tx.Commit();return new {count=entries.Count};});
    }
    static IEnumerable<int> Occurrences(string text,string quote){for(int start=0;start<text.Length;){var i=text.IndexOf(quote,start,StringComparison.Ordinal);if(i<0)yield break;yield return i;start=i+1;}}
    public record ParseOptions(string? Encoding,string? Pattern);
}
