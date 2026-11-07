using System.Security.Cryptography;
using System.Text.Json;

namespace Jitnote;

/// <summary>DownloadUrls are tried in order: Gitee first, GitHub as the fallback (design.md「检查更新」).</summary>
public sealed record AppRelease(string Version, string Notes, IReadOnlyList<string> DownloadUrls, long Size, string Sha256);

/// <summary>
/// Finds a newer version from the latest.json that each release carries on GitHub and on Gitee, and downloads
/// the Windows package. Both requests are anonymous: no token, no device identifier, nothing about the user's
/// notes. Does not replace the running program.
/// </summary>
public static class AppUpdates
{
    public const string Repo = "leon-mason/jitnote";
    public const string UserAgent = "Jitnote-Windows";
    public const long CheckIntervalMillis = 24 * 60 * 60 * 1000;
    const string Package = "windows-x64";

    /// <summary>
    /// Fixed addresses of the newest release's latest.json. scripts/release.sh uploads it last, after every
    /// package is on both sites. Gitee has no draft releases and counts the release edited last as the newest,
    /// which is why the release script never edits an older one.
    /// </summary>
    public static readonly IReadOnlyList<string> ManifestUrls =
    [
        "https://gitee.com/shitoupapa/jitnote/releases/download/latest/latest.json",
        "https://github.com/" + Repo + "/releases/latest/download/latest.json",
    ];

    // One client for the life of the app: disposing a client aborts its requests, and the slower latest.json
    // request must be allowed to finish (see Latest).
    static readonly HttpClient Http = CreateHttp();

    static HttpClient CreateHttp()
    {
        var http = new HttpClient();
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return http;
    }

    public static bool IsDue(long? lastSuccessMillis, long nowMillis) =>
        nowMillis - (lastSuccessMillis ?? 0) >= CheckIntervalMillis;

    public static bool IsNewer(string candidate, string current)
    {
        var a = Parts(candidate);
        var b = Parts(current);
        if (a == null || b == null) return false;
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var diff = (i < a.Length ? a[i] : 0) - (i < b.Length ? b[i] : 0);
            if (diff != 0) return diff > 0;
        }
        return false;
    }

    /// <summary>
    /// The newest version if it is newer than this app, else null. Asks GitHub and Gitee at once and takes
    /// whichever answers first, so users who cannot reach GitHub do not wait for it to time out. The slower
    /// request is left to finish: each download of latest.json on GitHub is what estimates daily users
    /// (design.md「检查更新」).
    /// </summary>
    public static async Task<AppRelease?> Latest(string currentVersion)
    {
        var release = await FirstSuccess(ManifestUrls.Select(url =>
            (Func<Task<AppRelease?>>)(async () => ParseManifest(await FetchText(url)))).ToList());
        return release != null && IsNewer(release.Version, currentVersion) ? release : null;
    }

    static async Task<string> FetchText(string url)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var response = await Http.GetAsync(url, timeout.Token);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException(url + " returned " + (int)response.StatusCode);
        return await response.Content.ReadAsStringAsync(timeout.Token);
    }

    /// <summary>
    /// Reads latest.json as written by scripts/release.sh. Throws when the file is unreadable, so the other
    /// site's answer can be used instead; null when it lists no usable package.
    /// </summary>
    public static AppRelease? ParseManifest(string json, string package = Package)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(json); }
        catch (JsonException e) { throw new InvalidDataException("Unreadable latest.json", e); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Text(root, "version") is not { } version)
                throw new InvalidDataException("latest.json has no version");
            if (version.StartsWith('v')) version = version[1..];
            if (!root.TryGetProperty("packages", out var packages) || packages.ValueKind != JsonValueKind.Object ||
                !packages.TryGetProperty(package, out var entry) || entry.ValueKind != JsonValueKind.Object)
                return null;
            if (!entry.TryGetProperty("size", out var sizeElement) || !sizeElement.TryGetInt64(out var size)) return null;
            var sha256 = Text(entry, "sha256")?.ToLowerInvariant();
            if (sha256 == null || sha256.Length != 64 || !sha256.All(Uri.IsHexDigit)) return null;
            var urls = new[] { Text(entry, "gitee"), Text(entry, "github") }
                .OfType<string>()
                .Where(url => url.StartsWith("https://", StringComparison.Ordinal))
                .ToList();
            if (urls.Count == 0) return null;
            var notes = (Text(root, "notes") ?? "").Replace("\r\n", "\n").Trim();
            return new AppRelease(version, notes, urls, size, sha256);
        }
    }

    /// <summary>
    /// Starts every attempt and returns the first result; throws only when all of them failed. The others
    /// are not cancelled.
    /// </summary>
    public static async Task<T> FirstSuccess<T>(IReadOnlyList<Func<Task<T>>> attempts)
    {
        var pending = attempts.Select(attempt => Task.Run(attempt)).ToList();
        Exception? last = null;
        while (pending.Count > 0)
        {
            var done = await Task.WhenAny(pending);
            pending.Remove(done);
            try { return await done; }
            catch (Exception e) { last = e; }
        }
        throw last ?? new InvalidOperationException("Nothing to try");
    }

    /// <summary>
    /// Downloads the package and returns its path, trying Gitee first and GitHub next. The caller opens the
    /// folder so the user can quit and swap the files.
    /// </summary>
    public static async Task<string> Download(AppRelease release, IProgress<long>? progress, CancellationToken cancel = default)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Jitnote-update-" + release.Version);
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        Directory.CreateDirectory(dir);
        var name = Path.GetFileName(new Uri(release.DownloadUrls[0]).AbsolutePath);
        if (string.IsNullOrEmpty(name)) name = "Jitnote-windows-x64.exe";
        var file = Path.Combine(dir, name);
        await DownloadVerified(release.DownloadUrls, file, release.Size, release.Sha256, async (url, target) =>
        {
            progress?.Report(0);
            await FetchFile(url, target, progress, cancel);
        }, cancel);
        return file;
    }

    static async Task FetchFile(string url, string file, IProgress<long>? progress, CancellationToken cancel)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException("status " + (int)response.StatusCode);
        await using var input = await response.Content.ReadAsStreamAsync(cancel);
        await using var output = File.Create(file);
        var buffer = new byte[64 * 1024];
        long total = 0;
        long last = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancel);
            if (read == 0) break;
            await output.WriteAsync(buffer.AsMemory(0, read), cancel);
            total += read;
            if (total - last >= 256 * 1024)
            {
                last = total;
                progress?.Report(total);
            }
        }
        progress?.Report(total);
    }

    /// <summary>
    /// Downloads into <paramref name="file"/> from each URL in turn until one gives exactly
    /// <paramref name="size"/> bytes with the expected SHA-256. A package that does not match is never kept,
    /// so it can never be opened.
    /// </summary>
    public static async Task DownloadVerified(IReadOnlyList<string> urls, string file, long size, string sha256,
        Func<string, string, Task> fetch, CancellationToken cancel = default)
    {
        Exception last = new InvalidOperationException("No download address");
        foreach (var url in urls)
        {
            cancel.ThrowIfCancellationRequested();
            try
            {
                await fetch(url, file);
                if (new FileInfo(file).Length == size && Sha256Of(file) == sha256) return;
                last = new IOException(url + " gave a different file");
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested)
            {
                File.Delete(file);
                throw;
            }
            catch (Exception e)
            {
                last = e;
            }
            File.Delete(file);
        }
        throw last;
    }

    public static string Sha256Of(string file)
    {
        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    static int[]? Parts(string version)
    {
        var text = version.StartsWith('v') ? version[1..] : version;
        var head = text.Split('-')[0];
        if (head.Length == 0) return null;
        var numbers = new List<int>();
        foreach (var piece in head.Split('.'))
        {
            if (!int.TryParse(piece, out var number)) return null;
            numbers.Add(number);
        }
        return numbers.Count == 0 ? null : numbers.ToArray();
    }
}
