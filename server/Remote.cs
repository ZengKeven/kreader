using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;

static class Remote
{
    static bool Public(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return false;
        var b = ip.GetAddressBytes();
        if (b.Length == 16) return (b[0] & 0xe0) == 0x20;
        return b[0] is not (0 or 10 or 127) && b[0] < 224 && !(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && b[1] is >= 16 and <= 31) && !(b[0] == 192 && b[1] == 168) && !(b[0] == 100 && b[1] is >= 64 and <= 127);
    }
    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        UseCookies = false,
        UseProxy = false,
        ConnectTimeout = TimeSpan.FromSeconds(8),
        ConnectCallback = async (ctx, ct) =>
        {
            var ips = await Dns.GetHostAddressesAsync(ctx.DnsEndPoint.Host, ct);
            var allowed = ips.Where(Public).ToArray();
            if (allowed.Length == 0) throw new HttpRequestException("书源地址须指向公网 HTTP(S) 站点");
            var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
            try { await socket.ConnectAsync(allowed, ctx.DnsEndPoint.Port, ct); return new NetworkStream(socket, true); } catch { socket.Dispose(); throw; }
        }
    })
    { Timeout = TimeSpan.FromSeconds(18), MaxResponseContentBufferSize = 10 * 1024 * 1024 };
    public static string Absolute(string baseUrl, string value)
    {
        if (string.IsNullOrWhiteSpace(value) || !Uri.TryCreate(new Uri(baseUrl), value.Trim(), out var uri) || uri.Scheme is not ("http" or "https")) return "";
        return uri.AbsoluteUri;
    }
    public static async Task<Asset?> FetchImage(string url, string referer, string header, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Referrer = new Uri(referer);
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0");
        request.Headers.Accept.ParseAdd("image/*");
        if (header.TrimStart().StartsWith('{'))
        {
            foreach (var (name, value) in JObject.Parse(header))
            {
                if (!name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) &&
                    !name.Equals("Referer", StringComparison.OrdinalIgnoreCase)) continue;
                request.Headers.Remove(name);
                request.Headers.TryAddWithoutValidation(name, value?.ToString());
            }
        }
        using var response = await Client.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        return BookCovers.Image(await response.Content.ReadAsByteArrayAsync(ct));
    }
    public static async Task<(string Url, string Body)> Fetch(string baseUrl, string spec, string keyword = "", string header = "", CancellationToken ct = default)
    {
        int cut = Regex.Match(spec, @",\s*\{") is { Success: true } m ? m.Index : -1;
        var options = cut < 0 ? new JObject() : JObject.Parse(spec[(cut + 1)..]);
        var enc = Encoding.GetEncoding(options.Field("charset") is { Length: > 0 } charset ? charset : "utf-8");
        string Expand(string value) => value.Replace("{{key}}", System.Web.HttpUtility.UrlEncode(keyword, enc)).Replace("{{page}}", "1").Replace("{{baseUrl}}", baseUrl).Replace("{{source.key}}", baseUrl);
        var url = Absolute(baseUrl, Expand(cut < 0 ? spec : spec[..cut])); if (url == "") throw new InvalidDataException("书源请求地址无效");
        using var req = new HttpRequestMessage(options.Field("method").Equals("POST", StringComparison.OrdinalIgnoreCase) ? HttpMethod.Post : HttpMethod.Get, url);
        req.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36");
        foreach (var obj in new[] { header.TrimStart().StartsWith('{') ? JObject.Parse(header) : null, options["headers"] as JObject })
        {
            if (obj == null) continue;
            foreach (var (key, val) in obj) if (key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) || key.Equals("Referer", StringComparison.OrdinalIgnoreCase) || key.Equals("Accept", StringComparison.OrdinalIgnoreCase))
            {
                req.Headers.Remove(key); req.Headers.TryAddWithoutValidation(key, val?.ToString());
            }
        }
        if (req.Method == HttpMethod.Post) req.Content = new StringContent(Expand(options.Field("body")), enc, "application/x-www-form-urlencoded");
        using var resp = await Client.SendAsync(req, ct); resp.EnsureSuccessStatusCode();
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct); var declared = resp.Content.Headers.ContentType?.CharSet?.Trim('"', '\'');
        if (string.IsNullOrWhiteSpace(declared))
        {
            var meta = Regex.Match(Encoding.ASCII.GetString(bytes, 0, Math.Min(bytes.Length, 3000)), """(?i)charset\s*=\s*["']?([a-z0-9_-]+)""");
            declared = meta.Success ? meta.Groups[1].Value : null;
        }
        return (resp.RequestMessage!.RequestUri!.AbsoluteUri, Ebooks.Decode(bytes, declared));
    }
}
