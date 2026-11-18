using Dapper;

record ReadingTimeBatch(ReadingTimePeriod[] Periods);
record ReadingTimePeriod(string Id, string BookId, string Title, string Author, long StartedAt, long EndedAt);

static class ReadingTime
{
    const int BatchLimit = 200;
    const int MaxPeriodMilliseconds = 5 * 60 * 1000;
    record Period(string BookId, long StartedAt, long EndedAt);
    record Edition(string BookId, string Title, string Author);
    record struct Interval(long Start, long End)
    {
        public long Length => End - Start;
    }

    public static void Map(WebApplication app, Library library)
    {
        using (var db = library.Open())
        {
            // Keep reading totals after a book is removed from the library.
            db.Execute("""
                CREATE TABLE IF NOT EXISTS reading_time_books (
                    BookId TEXT PRIMARY KEY, Title TEXT NOT NULL, Author TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS reading_time_periods (
                    Id TEXT PRIMARY KEY, BookId TEXT NOT NULL REFERENCES reading_time_books(BookId),
                    StartedAt INTEGER NOT NULL, EndedAt INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS ix_reading_time_start ON reading_time_periods(StartedAt,EndedAt);
                """);
        }
        app.MapPost("/api/reading-time", (ReadingTimeBatch batch) => Save(library, batch));
        app.MapGet("/api/reading-time", () => Summary(library));
    }

    static IResult Save(Library library, ReadingTimeBatch batch)
    {
        if (batch.Periods is not { Length: > 0 and <= BatchLimit })
            throw new InvalidDataException("阅读时长批次无效");

        var maxTimestamp = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds();
        foreach (var period in batch.Periods)
        {
            if (period is null || !Guid.TryParseExact(period.Id, "D", out _) ||
                string.IsNullOrWhiteSpace(period.BookId) || period.BookId.Length > 64 ||
                period.StartedAt < 0 || period.EndedAt > maxTimestamp ||
                period.EndedAt <= period.StartedAt || period.EndedAt - period.StartedAt > MaxPeriodMilliseconds)
                throw new InvalidDataException("阅读时长记录无效");
        }

        using var db = library.Open();
        using var tx = db.BeginTransaction(deferred: false);
        db.Execute("""
            INSERT INTO reading_time_books(BookId,Title,Author)
            SELECT @BookId, coalesce((SELECT Title FROM books WHERE Id=@BookId), @Title, ''),
                coalesce((SELECT Author FROM books WHERE Id=@BookId), @Author, '')
            ON CONFLICT(BookId) DO NOTHING
            """, batch.Periods.DistinctBy(p => p.BookId), tx);
        db.Execute("""
            INSERT INTO reading_time_periods(Id,BookId,StartedAt,EndedAt)
            VALUES(lower(@Id),@BookId,@StartedAt,@EndedAt) ON CONFLICT(Id) DO NOTHING
            """, batch.Periods, tx);
        tx.Commit();
        return Results.NoContent();
    }

    static object Summary(Library library)
    {
        var now = DateTimeOffset.UtcNow;
        var cutoff = now.ToUnixTimeMilliseconds();
        var zone = TimeZoneInfo.Local;
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
        var firstDay = today.AddMonths(-3).AddDays(1);
        var monthStart = new DateOnly(today.Year, today.Month, 1);
        using var db = library.Open();
        using var tx = db.BeginTransaction(deferred: true);
        var periods = db.Query<Period>("""
            SELECT BookId,StartedAt,EndedAt FROM reading_time_periods
            WHERE StartedAt < @cutoff ORDER BY StartedAt,EndedAt
            """, new { cutoff }, tx).AsList();
        var editions = db.Query("""
            SELECT r.BookId,coalesce(b.Title,r.Title) AS Title,coalesce(b.Author,r.Author) AS Author
            FROM reading_time_books r LEFT JOIN books b ON r.BookId=b.Id
            """, transaction: tx)
            .Select(r => new Edition((string)r.BookId, (string)r.Title, (string)r.Author))
            .ToDictionary(b => b.BookId);
        tx.Commit();

        var merged = Merge(periods, cutoff).ToList();
        var interval = 0;
        var days = new List<(DateOnly Date, long Milliseconds)>();
        for (var date = firstDay; date <= today; date = date.AddDays(1))
        {
            var start = Midnight(date, zone);
            var end = Midnight(date.AddDays(1), zone);
            while (interval < merged.Count && merged[interval].End <= start) interval++;
            long milliseconds = 0;
            for (var i = interval; i < merged.Count && merged[i].Start < end; i++)
                milliseconds += Math.Max(0, Math.Min(merged[i].End, end) - Math.Max(merged[i].Start, start));
            days.Add((date, milliseconds));
        }
        var month = days.Where(d => d.Date >= monthStart).ToList();

        var books = periods.Select(p => p.BookId).Distinct().Select(id => editions[id]).ToList();
        var knownAuthors = books.GroupBy(b => TitleKey(b.Title)).ToDictionary(
            g => g.Key, g => g.Select(b => AuthorKey(b.Author)).Where(a => a.Length > 0).ToHashSet());
        var workKeys = books.ToDictionary(b => b.BookId, b =>
        {
            var title = TitleKey(b.Title);
            var author = AuthorKey(b.Author);
            var authors = knownAuthors[title];
            if (title.Length == 0 || (author.Length == 0 && authors.Count > 1)) return ("", b.BookId);
            return (title, author.Length == 0 && authors.Count == 1 ? authors.Single() : author);
        });
        var ranking = periods.GroupBy(p => workKeys[p.BookId]).Select(g =>
        {
            var edition = g.Select(p => editions[p.BookId])
                .FirstOrDefault(b => AuthorKey(b.Author).Length > 0) ?? editions[g.First().BookId];
            return new
            {
                edition.BookId,
                title = BareTitle(edition.Title),
                author = AuthorKey(edition.Author).Length == 0 ? "" : edition.Author.Trim(),
                milliseconds = Merge(g, cutoff).Sum(i => i.Length)
            };
        }).OrderByDescending(b => b.milliseconds).ThenBy(b => b.title, StringComparer.Ordinal)
            .ThenBy(b => b.BookId, StringComparer.Ordinal).Take(10).ToList();

        return new
        {
            today,
            firstDay,
            todayMs = days[^1].Milliseconds,
            monthMs = month.Sum(d => d.Milliseconds),
            totalMs = merged.Sum(i => i.Length),
            activeDays = month.Count(d => d.Milliseconds > 0),
            days = days.Select(d => new { date = d.Date, milliseconds = d.Milliseconds }).ToList(),
            books = ranking
        };
    }

    // The database orders periods by start time. GroupBy preserves that order within each work.
    static IEnumerable<Interval> Merge(IEnumerable<Period> periods, long cutoff)
    {
        Interval? pending = null;
        foreach (var period in periods)
        {
            var end = Math.Min(period.EndedAt, cutoff);
            if (pending is { } previous && period.StartedAt <= previous.End)
                pending = new(previous.Start, Math.Max(previous.End, end));
            else
            {
                if (pending is { } completed) yield return completed;
                pending = new(period.StartedAt, end);
            }
        }
        if (pending is { } last) yield return last;
    }

    static long Midnight(DateOnly date, TimeZoneInfo zone)
    {
        var local = date.ToDateTime(TimeOnly.MinValue);
        while (zone.IsInvalidTime(local)) local = local.AddMinutes(1);
        var offset = zone.IsAmbiguousTime(local) ? zone.GetAmbiguousTimeOffsets(local).Max() : zone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset).ToUnixTimeMilliseconds();
    }

    static string BareTitle(string title)
    {
        title = title.Trim();
        return title.StartsWith('《') && title.EndsWith('》') ? title[1..^1].Trim() : title;
    }

    static string TitleKey(string title) => Compact(BareTitle(title));

    static string AuthorKey(string author)
    {
        var key = Compact(author);
        if (key.StartsWith("作者:", StringComparison.Ordinal) || key.StartsWith("作者：", StringComparison.Ordinal))
            key = key[3..];
        return key is "未知" or "未知作者" or "作者不详" or "佚名" ? "" : key;
    }

    static string Compact(string value) => new string(value.Where(c => !char.IsWhiteSpace(c)).ToArray()).ToLowerInvariant();
}
