using System.Text.Json;

namespace Jitnote;

public sealed record AppRelease(string Version, string Notes, string DownloadUrl, long Size);

/// <summary>
/// Finds a newer published release and downloads the Windows package. The request is anonymous:
/// no token, and nothing about the user's notes is sent.
/// </summary>
public static class AppUpdates
{
    public const string Repo = "leon-mason/jitnote";
    public const string UserAgent = "Jitnote-Windows";
    public const long CheckIntervalMillis = 24 * 60 * 60 * 1000;

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
    /// The Windows x64 zip from a public release. Mac packages and the Android package are ignored,
    /// as are drafts and pre-releases.
    /// </summary>
    public static AppRelease? ParseWindowsRelease(string json, string? currentVersion = null)
    {
        using var document = JsonDocument.Parse(json);
        var release = ParseWindowsRelease(document.RootElement);
        if (release == null || currentVersion == null) return release;
        return IsNewer(release.Version, currentVersion) ? release : null;
    }

    public static AppRelease? ParseWindowsRelease(JsonElement release)
    {
        if (Flag(release, "draft") || Flag(release, "prerelease")) return null;
        if (!release.TryGetProperty("tag_name", out var tag) || tag.GetString() is not { } version) return null;
        if (version.StartsWith('v')) version = version[1..];
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
        JsonElement? chosen = null;
        foreach (var asset in assets.EnumerateArray())
        {
            if (!asset.TryGetProperty("name", out var nameElement) || nameElement.GetString() is not { } name) continue;
            if (!name.Contains("windows", StringComparison.OrdinalIgnoreCase)) continue;
            if (!name.Contains("x64", StringComparison.OrdinalIgnoreCase)) continue;
            if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) continue;
            chosen = asset;
            break;
        }
        if (chosen == null) return null;
        if (!chosen.Value.TryGetProperty("browser_download_url", out var urlElement) || urlElement.GetString() is not { } url)
            return null;
        var notes = release.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String
            ? (body.GetString() ?? "").Replace("\r\n", "\n").Trim()
            : "";
        long size = 0;
        if (chosen.Value.TryGetProperty("size", out var sizeElement) && sizeElement.TryGetInt64(out var sizeValue)) size = sizeValue;
        return new AppRelease(version, notes, url, size);
    }

    public static async Task<AppRelease?> Latest(HttpClient http, string currentVersion, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/" + Repo + "/releases/latest");
        request.Headers.UserAgent.ParseAdd(UserAgent);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await http.SendAsync(request, cancel);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        if (!response.IsSuccessStatusCode) throw new HttpRequestException("status " + (int)response.StatusCode);
        var json = await response.Content.ReadAsStringAsync(cancel);
        var release = ParseWindowsRelease(json);
        return release != null && IsNewer(release.Version, currentVersion) ? release : null;
    }

    /// <summary>
    /// Downloads the zip and returns its path. Does not replace the running program; the caller opens
    /// the folder so the user can quit and swap the files.
    /// </summary>
    public static async Task<string> Download(HttpClient http, AppRelease release, IProgress<long>? progress, CancellationToken cancel = default)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Jitnote-update-" + release.Version);
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        Directory.CreateDirectory(dir);
        var name = Path.GetFileName(new Uri(release.DownloadUrl).AbsolutePath);
        if (string.IsNullOrEmpty(name)) name = "Jitnote-windows-x64.zip";
        var file = Path.Combine(dir, name);
        using var response = await http.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancel);
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
        if (release.Size > 0 && total != release.Size) throw new IOException("short download");
        return file;
    }

    static bool Flag(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

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
