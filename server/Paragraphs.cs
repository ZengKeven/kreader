using HtmlAgilityPack;
using System.Net;
using System.Text.RegularExpressions;

static class Paragraphs
{
    // Only expose data declared by the source; never run its image click handler.
    public static List<Block> Read(string html,string page)
    {
        if (!html.Contains("<img",StringComparison.OrdinalIgnoreCase))
            return Rules.Plain(html).Split('\n',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries).Select(t=>new Block(t)).ToList();
        var doc=new HtmlDocument();doc.LoadHtml(html);
        List<(string Count,string? Url,string? Text)> comments=[];
        foreach(var img in doc.DocumentNode.SelectNodes("//img")??new HtmlNodeCollection(doc.DocumentNode)){
            var src=WebUtility.HtmlDecode(img.GetAttributeValue("src",""));var count=Regex.Match(src,@"^dp:(\d{1,9})\b",RegexOptions.IgnoreCase);
            var link=img.Ancestors("a").FirstOrDefault()?.GetAttributeValue("href","")??img.GetAttributeValue("data-comment-url","");
            var body=WebUtility.HtmlDecode(img.GetAttributeValue("data-comment",""));
            if(!count.Success&&body==""&&img.GetAttributeValue("data-comment-count","")=="")continue;
            var label=count.Success?count.Groups[1].Value:img.GetAttributeValue("data-comment-count","1");
            var url=Remote.Absolute(page,link);img.ParentNode.ReplaceChild(doc.CreateTextNode("〔dp#"+comments.Count+"〕"),img);comments.Add((label,url,body));
        }
        List<Block> blocks=[];
        foreach(var line in Rules.Plain(doc.DocumentNode.InnerHtml).Split('\n',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries)){
            var m=Regex.Match(line,@"〔dp#(\d+)〕");var plain=Regex.Replace(line,@"〔dp#\d+〕","").Trim();if(!m.Success){if(plain!="")blocks.Add(new(plain));continue;}
            if(plain!="")blocks.Add(new(plain));if(blocks.Count==0)continue;
            var c=comments[int.Parse(m.Groups[1].Value)];blocks[^1]=blocks[^1] with{CommentCount=c.Count,CommentUrl=c.Url,CommentText=c.Text};
        }
        return blocks;
    }
}
