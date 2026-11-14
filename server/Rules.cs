using System.Net;
using System.Text.RegularExpressions;
using Fizzler.Systems.HtmlAgilityPack;
using HtmlAgilityPack;
using Newtonsoft.Json.Linq;

static class Rules
{
    public static bool Script(string s) => Regex.IsMatch(s, @"(?i)<js\b|@js:|\b(java|cookie|cache)\.|""webView""\s*:\s*true|source\.get|\{\{(?!\s*(?:key|page|baseUrl|source\.key|title|\$[^}]+)\s*\}\})");
    public static string Field(this JToken? root, string key) => root?[key]?.ToString() ?? "";
    public static string Diagnose(JObject s)
    {
        if (s.Value<int?>("bookSourceType") is > 0) return "非文字书源";
        foreach (var (group, fields) in new[] { ("", new[] { "searchUrl", "header" }), ("ruleSearch", new[] { "bookList", "name", "bookUrl" }), ("ruleBookInfo", new[] { "init", "tocUrl" }), ("ruleToc", new[] { "chapterList", "chapterName", "chapterUrl", "nextTocUrl" }), ("ruleContent", new[] { "content", "nextContentUrl", "replaceRegex" }) })
            foreach (var field in fields) if (Script((group == "" ? s : s[group]).Field(field))) return (group == "" ? "" : group + ".") + field + " 需要脚本或 WebView";
        if (new[] { "searchUrl", "ruleSearch", "ruleToc", "ruleContent" }.Any(k => s.Field(k).Length == 0)) return "缺少搜索、目录或正文规则";
        return "";
    }
    public static object Document(string body)
    {
        var t = body.TrimStart('\uFEFF', ' ', '\t', '\r', '\n');
        if (t.StartsWith('{') || t.StartsWith('[')) { try { return JToken.Parse(t); } catch (Newtonsoft.Json.JsonException) { } }
        var doc = new HtmlDocument(); doc.LoadHtml(body); return doc.DocumentNode;
    }
    static IEnumerable<object> Html(HtmlNode root, string raw)
    {
        var rule = raw.Trim().Replace("@css:", "", StringComparison.OrdinalIgnoreCase);
        if (rule.StartsWith("@XPath:", StringComparison.OrdinalIgnoreCase)) rule = rule[7..];
        if (rule.StartsWith('/') || rule.StartsWith("./"))
        {
            string? attr = null; var match = Regex.Match(rule, @"/(?:@([\w:-]+)|(text|html)\(\))$");
            if (match.Success) { attr = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value; rule = rule[..match.Index]; }
            var nodes = root.SelectNodes(rule)?.AsEnumerable() ?? [];
            return attr == null ? nodes.Cast<object>() : nodes.Select(n => (object)Value(n, attr));
        }
        List<HtmlNode> current = [root];
        var steps = rule.TrimStart('@').Split('@', StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i < steps.Length; i++)
        {
            var step = steps[i].Trim();
            if (i == steps.Length - 1 && (step is "text" or "textNodes" or "ownText" or "html" or "all" or "href" or "src" or "content" or "title" or "value" or "data-src" or "alt" || step.StartsWith("data-"))) return current.Select(n => (object)Value(n, step));
            var index = Regex.Match(step, @"([.!])(-?\d+)$");
            if (index.Success) step = step[..index.Index];
            var selector = step.StartsWith("class.") ? "." + step[6..].Replace(' ', '.') : step.StartsWith("id.") ? "#" + step[3..] : step.StartsWith("tag.") ? step[4..] : step;
            var found = new List<HtmlNode>();
            foreach (var parent in current)
            {
                var list = (step == "children" ? parent.ChildNodes.Where(n => n.NodeType == HtmlNodeType.Element) : step.StartsWith("text.") ? parent.Descendants("a").Where(n => Visible(n) == step[5..]) : parent.Name == selector ? new[] { parent } : parent.QuerySelectorAll(selector)).ToList();
                if (index.Success) { var pos = int.Parse(index.Groups[2].Value); if (pos < 0) pos += list.Count; list = index.Groups[1].Value == "!" ? list.Where((_, j) => j != pos).ToList() : list.Skip(Math.Max(0, pos)).Take(pos < 0 ? 0 : 1).ToList(); }
                found.AddRange(list);
            }
            current = found;
        }
        return current.Cast<object>();
    }
    static string Value(HtmlNode n, string mode) => mode switch { "text" => Visible(n), "textNodes" or "ownText" => string.Join("\n", n.ChildNodes.Where(c => c.NodeType == HtmlNodeType.Text).Select(c => WebUtility.HtmlDecode(c.InnerText).Trim()).Where(s => s != "")), "html" or "all" => n.InnerHtml, _ => WebUtility.HtmlDecode(n.GetAttributeValue(mode, "")) };
    public static string Visible(HtmlNode n) => WebUtility.HtmlDecode(n.InnerText).Trim();
    public static string Plain(string html)
    {
        html = Regex.Replace(html, @"(?is)<(script|style)\b[^>]*>.*?</\1>", "");
        html = Regex.Replace(html, @"(?i)<br\b[^>]*>|</(?:p|div|li|h[1-6])>", "\n");
        var doc = new HtmlDocument(); doc.LoadHtml(html); return Visible(doc.DocumentNode);
    }
    public static List<object> Select(object root, string rule)
    {
        if (Script(rule)) throw new NotSupportedException("规则需要脚本");
        foreach (var alternative in rule.Split("||", StringSplitOptions.TrimEntries))
        {
            var found = new List<object>();
            foreach (var part in alternative.Split("&&", StringSplitOptions.TrimEntries))
            {
                var expression = part.Split("##")[0].Trim();
                if (expression.Length == 0) continue;
                if (root is JToken token)
                {
                    var path = Regex.Replace(expression, @"^(?:@json:|@Json:)", "");
                    var matches = token.SelectTokens(path).SelectMany(t => t is JArray arr ? arr.AsEnumerable() : new[] { t });
                    found.AddRange(matches.Cast<object>());
                }
                else if (root is HtmlNode node) found.AddRange(Html(node, expression));
            }
            if (found.Any(x => x is not string s || s.Length > 0)) return found;
        }
        return [];
    }
    public static string Text(object root, string rule)
    {
        if (string.IsNullOrWhiteSpace(rule) || Script(rule)) return "";
        if (root is JToken token && rule.Contains("{{$")) return Regex.Replace(rule, @"\{\{(\$[^}]+)\}\}", m => token.SelectToken(m.Groups[1].Value)?.ToString() ?? "");
        if (rule.StartsWith("https://") || rule.StartsWith("http://")) return rule;
        foreach (var alt in rule.Split("||", StringSplitOptions.TrimEntries))
        {
            var parts = alt.Split("##");
            var text = string.Join("\n", Select(root, parts[0]).Select(x => x is HtmlNode n ? Visible(n) : x.ToString()).Where(s => !string.IsNullOrWhiteSpace(s)));
            if (parts.Length > 1 && parts[1].Length > 0)
            {
                try { text = Regex.Replace(text, parts[1], parts.Length > 2 ? parts[2] : "", RegexOptions.NonBacktracking, TimeSpan.FromSeconds(1)); }
                catch (NotSupportedException) { text = Regex.Replace(text, parts[1], parts.Length > 2 ? parts[2] : "", RegexOptions.None, TimeSpan.FromMilliseconds(400)); }
            }
            if (!string.IsNullOrWhiteSpace(text)) return text.Trim();
        }
        return "";
    }
    public static string Optional(object root, string rule) { try { return Text(root, rule); } catch (Exception) { return ""; } }
}
