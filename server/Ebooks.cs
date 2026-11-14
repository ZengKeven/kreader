using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

static class Ebooks
{
    public static string Decode(byte[] bytes, string? encoding)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        if (!string.IsNullOrWhiteSpace(encoding) && encoding != "auto") return Encoding.GetEncoding(encoding).GetString(bytes).TrimStart('\uFEFF');
        if (bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe })) return Encoding.Unicode.GetString(bytes).TrimStart('\uFEFF');
        if (bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff })) return Encoding.BigEndianUnicode.GetString(bytes).TrimStart('\uFEFF');
        try { return new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF'); }
        catch (DecoderFallbackException) { return Encoding.GetEncoding("GB18030").GetString(bytes); }
    }
    public static Parsed Txt(byte[] bytes, string filename, string? encoding, string? pattern=null)
    {
        var title = Path.GetFileNameWithoutExtension(filename);
        var result = new Parsed(title, "", [], []);
        var sections = new List<Block>(); var heading = "正文"; int size = 0, part = 0;
        void Flush() { if (sections.Count == 0) return; result.Chapters.Add((heading, sections)); sections = []; size = 0; }
        foreach (var raw in Decode(bytes, encoding).Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = raw.Trim(); if (line.Length == 0) continue;
            if (line.Length <= 90 && Regex.IsMatch(line, string.IsNullOrWhiteSpace(pattern) ? @"^(第[〇零一二三四五六七八九十百千万两\d０-９]+[章回节卷部篇]|序[章言幕]|楔子|尾声|后记|chapter\s+\d+)" : pattern, RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(100)))
            {
                Flush(); heading = line; sections.Add(new Block(line, "heading")); continue;
            }
            for (int i = 0; i < line.Length; i += 2048)
            {
                if (size >= 16000) { Flush(); heading = "续读 · " + (++part); }
                var fragment = line.Substring(i, Math.Min(2048, line.Length - i)); sections.Add(new Block(fragment)); size += fragment.Length;
            }
        }
        Flush(); return result;
    }
    static string Resolve(string file, string relative)
    {
        var uri = new Uri(new Uri("https://epub.invalid/" + file), relative);
        if (uri.Host != "epub.invalid") return "";
        return Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')) + Uri.UnescapeDataString(uri.Fragment);
    }
    static string Attr(XElement? x, string key) => x?.Attributes().FirstOrDefault(a => a.Name.LocalName == key)?.Value ?? "";
    static string Mark(XNode x)
    {
        if (x is XText t) return WebUtility.HtmlEncode(t.Value);
        if (x is not XElement e) return "";
        var name = e.Name.LocalName.ToLowerInvariant();
        if (name is "script" or "style" or "img" or "image") return "";
        if (name == "br") return "\n";
        var body = string.Concat(e.Nodes().Select(Mark));
        return name is "em" or "i" or "strong" or "b" ? "<" + name + ">" + body + "</" + name + ">" : body;
    }
    public static Parsed Epub(string file, string filename)
    {
        using var archive = ZipFile.OpenRead(file);
        if (archive.Entries.Count > 12000 || archive.Entries.Sum(e => e.Length) > 320L * 1024 * 1024) throw new InvalidDataException("EPUB 解压后超过处理上限");
        var files = archive.Entries.GroupBy(e => e.FullName, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        XDocument Xml(string path)
        {
            if (!files.TryGetValue(path, out var entry)) throw new InvalidDataException("EPUB 缺少 " + path);
            using var input = entry.Open(); return XDocument.Load(input, LoadOptions.PreserveWhitespace);
        }
        var opfPath = Attr(Xml("META-INF/container.xml").Descendants().FirstOrDefault(e => e.Name.LocalName == "rootfile"), "full-path");
        var opf = Xml(opfPath);
        var result = new Parsed(opf.Descendants().FirstOrDefault(e => e.Name.LocalName == "title")?.Value ?? Path.GetFileNameWithoutExtension(filename), opf.Descendants().FirstOrDefault(e => e.Name.LocalName == "creator")?.Value ?? "", [], []);
        var items = opf.Descendants().Where(e => e.Name.LocalName == "item").ToDictionary(e => Attr(e, "id"));
        var names = new Dictionary<string, string>();
        foreach (var item in items.Values.Where(e => Attr(e, "properties").Split(' ').Contains("nav") || Attr(e, "media-type").Contains("ncx")))
        {
            var path = Resolve(opfPath, Attr(item, "href")); var nav = Xml(path);
            foreach (var point in nav.Descendants().Where(e => e.Name.LocalName == "navPoint"))
            {
                var dst = Attr(point.Elements().FirstOrDefault(e => e.Name.LocalName == "content"), "src");
                var label = point.Elements().FirstOrDefault(e => e.Name.LocalName == "navLabel")?.Value.Trim();
                if (dst != "" && !string.IsNullOrWhiteSpace(label)) names.TryAdd(Resolve(path, dst), label);
            }
            foreach (var a in nav.Descendants().Where(e => e.Name.LocalName == "a" && e.Ancestors().Any(n => n.Name.LocalName == "nav" && (Attr(n, "type") == "" || Attr(n, "type").Split(' ').Contains("toc")))))
                names.TryAdd(Resolve(path, Attr(a, "href")), a.Value.Trim());
        }
        foreach (var spine in opf.Descendants().Where(e => e.Name.LocalName == "itemref" && Attr(e, "linear") != "no"))
        {
            if (!items.TryGetValue(Attr(spine, "idref"), out var item)) continue;
            var path = Resolve(opfPath, Attr(item, "href")); var doc = Xml(path);
            var body = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "body"); if (body == null) continue;
            string heading = names.GetValueOrDefault(path) ?? body.Descendants().FirstOrDefault(e => e.Name.LocalName is "h1" or "h2")?.Value.Trim() ?? doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "title")?.Value.Trim() ?? "第 " + (result.Chapters.Count + 1) + " 节";
            List<Block> blocks = []; var inline = new StringBuilder();
            void FlushText(string kind = "p")
            {
                var markup = inline.ToString().Trim(); inline.Clear();
                var text = WebUtility.HtmlDecode(Regex.Replace(markup, "</?(strong|b|em|i)>", "")).Trim();
                if (text != "") blocks.Add(new Block(text, kind, null, markup));
            }
            void FlushChapter() { FlushText(); if (blocks.Count > 0) { result.Chapters.Add((heading, blocks)); blocks = []; } }
            void Walk(XNode node, string kind)
            {
                if (node is XText t) { inline.Append(WebUtility.HtmlEncode(t.Value)); return; }
                if (node is not XElement e) return;
                var tag = e.Name.LocalName.ToLowerInvariant(); if (tag is "script" or "style") return;
                if (Attr(e, "id") is { Length: > 0 } frag && names.TryGetValue(path + "#" + frag, out var label)) { FlushChapter(); heading = label; }
                if (tag is "img" or "image")
                {
                    FlushText(kind); var target = Resolve(path, Attr(e, tag == "img" ? "src" : "href"));
                    if (files.TryGetValue(target, out var entry))
                    {
                        string key = Library.Key(target);
                        if (!result.Assets.ContainsKey(key))
                        {
                            var mime = Path.GetExtension(target).ToLowerInvariant() switch { ".png" => "image/png", ".webp" => "image/webp", ".gif" => "image/gif", _ => "image/jpeg" };
                            using var input = entry.Open(); using var output = new MemoryStream(); input.CopyTo(output); result.Assets[key] = new Asset(output.ToArray(), mime);
                        }
                        blocks.Add(new Block(Attr(e, "alt"), "image", key));
                    }
                    return;
                }
                if (tag == "br") { FlushText(kind); return; }
                bool boundary = tag is "p" or "div" or "section" or "li" or "blockquote" or "h1" or "h2" or "h3" or "h4";
                if (boundary) FlushText(kind);
                var childKind = tag is "h1" or "h2" or "h3" or "h4" ? "heading" : kind;
                if (tag is "em" or "strong" or "b" or "i" && !e.Descendants().Any(x => x.Name.LocalName is "img" or "image")) inline.Append(Mark(e));
                else foreach (var child in e.Nodes()) Walk(child, childKind);
                if (boundary) FlushText(childKind);
            }
            Walk(body, "p"); FlushChapter();
        }
        return result;
    }
}
