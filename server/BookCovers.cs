using System.IO.Compression;
using System.Net;
using System.Xml.Linq;
using Dapper;
using HtmlAgilityPack;
using Newtonsoft.Json.Linq;

sealed class BookCovers(Library library)
{
    // A shelf, a search page and the details sheet can request the same image together.
    readonly SemaphoreSlim[] gates = Enumerable.Range(0, 32).Select(_ => new SemaphoreSlim(1)).ToArray();
    record Cache(string Source, byte[]? Data, string? Mime, long RetryAt);

    public async Task<Asset?> Get(string id, CancellationToken ct)
    {
        var gate = gates[(int)((uint)StringComparer.Ordinal.GetHashCode(id) % gates.Length)];
        await gate.WaitAsync(ct);
        try
        {
            using var db = library.Open();
            var book = library.Get(id);
            var cached = db.QuerySingleOrDefault<Cache>("SELECT Source,Data,Mime,RetryAt FROM covers WHERE BookId=@id", new { id });
            var source = book.Origin == "local" ? book.Url : book.Cover;
            if (cached?.Source == source && (cached.Data != null || cached.RetryAt > Library.Now))
                return cached.Data == null ? null : new Asset(cached.Data, cached.Mime!);

            Asset? result;
            if (book.Origin == "local")
            {
                if (book.Url != ".epub") return null;
                result = EpubCover(Path.Combine(library.Root, "originals", book.Id + ".epub"));
            }
            else
            {
                var raw = db.ExecuteScalar<string>("SELECT Raw FROM sources WHERE Id=@origin", new { origin = book.Origin });
                var rule = raw == null ? new JObject() : JObject.Parse(raw);
                try { (result, source) = await Online(book, rule, ct); }
                catch (HttpRequestException) { result=null; }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { result=null; }
            }

            if (result == null && cached?.Data != null)
                return new Asset(cached.Data,cached.Mime!);
            using var tx = db.BeginTransaction();
            if (result != null && book.Origin != "local" && book.Cover != source)
                db.Execute("UPDATE books SET Cover=@source WHERE Id=@id AND Cover=@original", new { id, source, original = book.Cover }, tx);
            db.Execute("INSERT OR REPLACE INTO covers(BookId,Source,Data,Mime,RetryAt) VALUES(@id,@source,@data,@mime,@retry)", new {
                id, source, data = result?.Data, mime = result?.Mime,
                retry = Library.Now + (book.Origin == "local" ? TimeSpan.FromDays(7) : TimeSpan.FromMinutes(5)).TotalMilliseconds
            },tx);
            tx.Commit();
            return result;
        }
        finally { gate.Release(); }
    }

    static async Task<(Asset?,string)> Online(Book book, JObject rule, CancellationToken ct)
    {
        var header = rule.Field("header");
        var attempted = new HashSet<string>(StringComparer.Ordinal);
        async Task<Asset?> TryImage(string candidate)
        {
            if (candidate == "" || !attempted.Add(candidate)) return null;
            try { return await Remote.FetchImage(candidate, book.Url, header, ct); }
            catch (HttpRequestException) { return null; }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return null; }
        }
        if (await TryImage(book.Cover) is { } known) return (known, book.Cover);
        var page = await Remote.Fetch(book.Url, book.Url, header:header, ct:ct);
        var root = Rules.Document(page.Body);
        var info = rule["ruleBookInfo"];
        var scope = info.Field("init") is {Length: >0} init ? Rules.Select(root,init).FirstOrDefault() ?? root : root;
        var paths = new List<string> { Rules.Optional(scope,info.Field("coverUrl")) };
        if (root is HtmlNode html)
        {
            foreach (var tag in html.Descendants("meta"))
            {
                var property = tag.GetAttributeValue("property", tag.GetAttributeValue("name","")).ToLowerInvariant();
                if (property is "og:image" or "og:image:url" or "og:image:secure_url" or "twitter:image" or "twitter:image:src")
                    paths.Add(tag.GetAttributeValue("content",""));
            }
            foreach (var img in html.Descendants("img").Where(n=>n.GetAttributeValue("alt","").Trim()==book.Title ||
                    n.AncestorsAndSelf().Take(2).Any(p => p.GetAttributeValue("class","").Contains("cover", StringComparison.OrdinalIgnoreCase))).Take(1))
                paths.Add(img.GetAttributeValue("data-original",img.GetAttributeValue("data-src",img.GetAttributeValue("src",""))));
        }
        foreach (var path in paths)
        {
            var url = Remote.Absolute(page.Url,WebUtility.HtmlDecode(path.Trim()));
            if (await TryImage(url) is { } image) return (image,url);
        }
        return (null,book.Cover);
    }

    public static Asset? Image(byte[] bytes)
    {
        var b=bytes.AsSpan();
        if (b.Length<12 || b.Length>10*1024*1024) return null;
        var mime = b.StartsWith(new byte[]{0xff,0xd8,0xff}) ? "image/jpeg" :
            b.StartsWith(new byte[]{137,80,78,71,13,10,26,10}) ? "image/png" :
            b.StartsWith("GIF87a"u8) || b.StartsWith("GIF89a"u8) ? "image/gif" :
            b.StartsWith("RIFF"u8) && b[8..].StartsWith("WEBP"u8) ? "image/webp" : null;
        return mime == null ? null : new Asset(bytes,mime);
    }

    static Asset? EpubCover(string file)
    {
        using var archive=ZipFile.OpenRead(file);
        XDocument? Xml(string path)
        {
            var entry=archive.GetEntry(path);
            if (entry==null || entry.Length>4*1024*1024) return null;
            using var input=entry.Open();
            return XDocument.Load(input);
        }
        static string Attr(XElement e,string name) => e.Attributes().FirstOrDefault(a=>a.Name.LocalName==name)?.Value ?? "";
        static string Resolve(string path,string href)
        {
            if(string.IsNullOrWhiteSpace(href) || !Uri.TryCreate(new Uri("https://epub.invalid/"+path),href,out var result) || result.Host!="epub.invalid") return "";
            return Uri.UnescapeDataString(result.AbsolutePath.TrimStart('/'));
        }
        Asset? ReadImage(string path)
        {
            var entry=archive.GetEntry(path);
            if(entry==null || entry.Length is <=0 or >10*1024*1024) return null;
            using var input=entry.Open();
            using var output=new MemoryStream();
            input.CopyTo(output);
            return Image(output.ToArray());
        }
        var package=Xml("META-INF/container.xml")?.Descendants().FirstOrDefault(e=>e.Name.LocalName=="rootfile");
        if(package==null)return null;
        var path=Attr(package,"full-path");
        var opf=Xml(path);
        if(opf==null)return null;
        var items=opf.Descendants().Where(e=>e.Name.LocalName=="item").ToList();
        var meta=opf.Descendants().FirstOrDefault(e=>e.Name.LocalName=="meta" && Attr(e,"name").Equals("cover",StringComparison.OrdinalIgnoreCase));
        var guide=opf.Descendants().Where(e=>e.Name.LocalName=="reference" && Attr(e,"type")=="cover");
        var candidates=items.Where(e=>Attr(e,"properties").Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries).Contains("cover-image"))
            .Concat(items.Where(e=>meta!=null && Attr(e,"id")==Attr(meta,"content")))
            .Concat(guide)
            .Concat(items.Where(e=>Path.GetFileNameWithoutExtension(Attr(e,"href")).Equals("cover",StringComparison.OrdinalIgnoreCase)));
        foreach(var entry in candidates.Distinct())
        {
            var cover=Resolve(path,Attr(entry,"href"));
            if(ReadImage(cover) is { } image)return image;
            if(Path.GetExtension(cover).ToLowerInvariant() is not (".xhtml" or ".html" or ".svg" or ".htm"))continue;
            foreach(var node in Xml(cover)?.Descendants().Where(e=>e.Name.LocalName is "img" or "image") ?? [])
                if(ReadImage(Resolve(cover,Attr(node,node.Name.LocalName=="img"?"src":"href"))) is { } wrapped)return wrapped;
        }
        return null;
    }
}
