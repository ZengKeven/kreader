using Dapper;
using Newtonsoft.Json.Linq;

class Catalog(Library library)
{
    public object Import(string json, string? editing = null)
    {
        var parsed = JToken.Parse(json);
        IEnumerable<JToken> rows = parsed is JArray a ? a : new[] { parsed };
        var report = new List<object>(); using var db = library.Open(); using var tx = db.BeginTransaction();
        foreach (var row in rows)
        {
            if (row is not JObject s || s.Field("bookSourceName") == "" || !Uri.TryCreate(s.Field("bookSourceUrl"), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            {
                report.Add(new { name = row is JObject ? row.Field("bookSourceName") : "", issue = "无效书源名称或地址", imported = false }); continue;
            }
            var id = Library.Key(s.Field("bookSourceUrl"));
            if (editing != null && editing != id) throw new InvalidDataException("修改来源地址请作为新书源导入");
            var issue = Rules.Diagnose(s);
            var src = new Source(id, s.Field("bookSourceName"), s.Field("bookSourceGroup"), s.Value<bool?>("enabled") == false ? 0 : 1, issue, s.ToString(Newtonsoft.Json.Formatting.None));
            db.Execute("""INSERT INTO sources VALUES(@Id,@Name,@GroupName,@Enabled,@Issue,@Raw) ON CONFLICT(Id) DO UPDATE SET Name=excluded.Name,GroupName=excluded.GroupName,Issue=excluded.Issue,Raw=excluded.Raw""", src, tx);
            report.Add(new { id, name = src.Name, issue, imported = true });
        }
        tx.Commit(); return report;
    }
    static void Verify(Source src) { if (src.Enabled == 0) throw new InvalidDataException("书源已停用"); if (src.Issue != "") throw new NotSupportedException(src.Issue); }
    public async Task<List<Book>> Search(string id, string query, CancellationToken ct)
    {
        var src = library.Source(id); Verify(src);
        var source = JObject.Parse(src.Raw); var rule = source["ruleSearch"];
        var (url, body) = await Remote.Fetch(source.Field("bookSourceUrl"), source.Field("searchUrl"), query, source.Field("header"), ct);
        var root = Rules.Document(body); var hits = new Dictionary<string, Book>();
        foreach (var node in Rules.Select(root, rule.Field("bookList")).Take(40))
        {
            var title = Rules.Text(node, rule.Field("name"));
            var link = Remote.Absolute(url, Rules.Text(node, rule.Field("bookUrl")));
            if (link == "" || title == "") continue;
            var book = new Book(Library.Key(id + "|" + link), Rules.Plain(title), Rules.Plain(Rules.Optional(node, rule.Field("author"))), id, link, Rules.Plain(Rules.Optional(node, rule.Field("intro"))), Remote.Absolute(url, Rules.Optional(node, rule.Field("coverUrl"))), 0, 0);
            library.SaveSearch(book); hits[book.Id] = book;
        }
        return hits.Values.ToList();
    }
    public async Task<List<object>> Contents(Book book, bool refresh, CancellationToken ct)
    {
        var existing = library.Toc(book.Id);
        if (book.Origin == "local" || (!refresh && existing.Count > 0)) return existing;
        var src = library.Source(book.Origin); Verify(src); var s = JObject.Parse(src.Raw); var toc = s["ruleToc"]; var info = s["ruleBookInfo"];
        var page = await Remote.Fetch(book.Url, book.Url, header: s.Field("header"), ct: ct);
        var root = Rules.Document(page.Body);
        if (info.Field("init") is { Length: > 0 } init) root = Rules.Select(root, init).FirstOrDefault() ?? root;
        string Detail(string key, string fallback) { var value = Rules.Optional(root, info.Field(key)); return value.Length > 0 ? value : fallback; }
        library.SaveSearch(book with { Title = Detail("name", book.Title), Author = Detail("author", book.Author), Intro = Rules.Plain(Detail("intro", book.Intro)), Cover = Remote.Absolute(page.Url, Detail("coverUrl", book.Cover)) });
        var tocUrl = Remote.Absolute(page.Url, Rules.Text(root, info.Field("tocUrl")));
        if (tocUrl != "" && tocUrl != page.Url) page = await Remote.Fetch(page.Url, tocUrl, header: s.Field("header"), ct: ct);
        var entries = new List<Entry>(); var ids = new HashSet<string>(); var visited = new HashSet<string>(); var queue = new Queue<string>();
        var listRule = toc.Field("chapterList"); bool reverse = listRule.StartsWith('-'); listRule = listRule.TrimStart('-', '+');
        while (visited.Add(page.Url))
        {
            var doc = Rules.Document(page.Body);
            foreach (var node in Rules.Select(doc, listRule))
            {
                var title = Rules.Text(node, toc.Field("chapterName")); var href = Rules.Text(node, toc.Field("chapterUrl"));
                var url = Remote.Absolute(page.Url, href); if (title == "" || url == "" || !ids.Add(url)) continue;
                entries.Add(new Entry(Library.Key(book.Id + "|" + url), book.Id, title, entries.Count, url, ""));
            }
            foreach (var href in Rules.Text(doc, toc.Field("nextTocUrl")).Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var next = Remote.Absolute(page.Url, href); if (next != "" && !visited.Contains(next) && !queue.Contains(next)) queue.Enqueue(next);
            }
            while (queue.Count > 0 && visited.Contains(queue.Peek())) queue.Dequeue();
            if (queue.Count == 0) break; if (visited.Count >= 128) throw new InvalidDataException("目录分页超过 128 页");
            page = await Remote.Fetch(page.Url, queue.Dequeue(), header: s.Field("header"), ct: ct);
        }
        if (entries.Count == 0) throw new InvalidDataException("目录为空，书源规则可能失效");
        if (reverse) { entries.Reverse(); entries = entries.Select((e, i) => e with { Ord = i }).ToList(); }
        library.ReplaceToc(book.Id, entries); return library.Toc(book.Id);
    }
    public async Task<object> Chapter(string id, string chapter, CancellationToken ct)
    {
        using var db = library.Open(); var e = db.QuerySingleOrDefault<Entry>("SELECT * FROM chapters WHERE Id=@chapter AND BookId=@id", new { id, chapter }) ?? throw new KeyNotFoundException("未找到章节");
        if (e.Body != "") return new { id = e.Id, title = e.Title, blocks = System.Text.Json.JsonDocument.Parse(e.Body).RootElement };
        var book = library.Get(id); var src = library.Source(book.Origin); Verify(src); var s = JObject.Parse(src.Raw); var rule = s["ruleContent"];
        List<Block> blocks = []; HashSet<string> visited = []; var next = e.Url;
        while (next != "" && visited.Add(next))
        {
            var page = await Remote.Fetch(next, next, header: s.Field("header"), ct: ct);
            var root = Rules.Document(page.Body);
            var content = Rules.Text(root, rule.Field("content").Replace("{{title}}", System.Text.RegularExpressions.Regex.Escape(e.Title)));
            var replace = rule.Field("replaceRegex").Split("##"); if (replace.Length > 1 && replace[1] != "") content = System.Text.RegularExpressions.Regex.Replace(content, replace[1], replace.Length > 2 ? replace[2] : "", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromMilliseconds(400));
            var lines = Paragraphs.Read(content,page.Url);
            if (lines.Count == 0) throw new InvalidDataException("本页没有可读正文");
            blocks.AddRange(lines);
            next = Remote.Absolute(page.Url, Rules.Text(root, rule.Field("nextContentUrl")).Split('\n')[0]);
            if (next != "" && db.ExecuteScalar<int>("SELECT count(*) FROM chapters WHERE BookId=@id AND Url=@next AND Id<>@chapter", new { id, next, chapter }) > 0) break;
            if (visited.Count >= 32 && next != "") throw new InvalidDataException("正文分页超过 32 页");
        }
        return new { id = e.Id, title = e.Title, blocks };
    }
}
