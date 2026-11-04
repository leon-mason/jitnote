using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Jitnote;

public sealed class RemoteUser
{
    public required string Login { get; init; }
    public required string Email { get; init; }
}

public sealed class CreatedRepo
{
    public required string CloneUrl { get; init; }
    public required string WebUrl { get; init; }
}

public sealed class RemoteRepo
{
    public required string Path { get; init; }
    public required string DisplayName { get; init; }
    public required string CloneUrl { get; init; }
    public required bool IsNotebook { get; init; }
    public required bool IsPrivate { get; init; }
    public required string Owner { get; init; }
    public long? UpdatedAt { get; init; }
    public long? SizeKb { get; init; }
}

public sealed class NameTakenException : Exception
{
}

/// <summary>
/// The few platform calls the app needs: who owns this token, create a private notebook, list notebooks.
/// Notes themselves never go through these calls.
/// </summary>
public sealed class HostingApi
{
    public const string NotebookMark = "[Jitnote]";
    public const string UserAgent = "Jitnote-Windows";
    const int PageSize = 100;
    // Five pages is the cap Mac and Android share, so a huge account still finishes.
    const int MaxPages = 5;

    readonly HttpMessageHandler? handler;

    public HostingApi(HttpMessageHandler? handler = null) => this.handler = handler;

    public async Task<RemoteUser> Verify(Provider provider, string token, CancellationToken cancel = default)
    {
        var url = provider == Provider.GITHUB ? "https://api.github.com/user" : "https://gitee.com/api/v5/user";
        var json = await Request(provider, token, HttpMethod.Get, url, null, cancel) as JsonElement?;
        if (json == null || json.Value.ValueKind != JsonValueKind.Object || !TryString(json.Value, "login", out var login))
            throw new SyncException(SyncErrorKind.Other, "无法读取账号信息");
        TryString(json.Value, "id", out var id);
        var email = TryString(json.Value, "email", out var raw) && raw.Length > 0 ? raw : null;
        email ??= provider == Provider.GITHUB
            ? id + "+" + login + "@users.noreply.github.com"
            : id + "+" + login + "@user.noreply.gitee.com";
        return new RemoteUser { Login = login, Email = email };
    }

    public async Task<IReadOnlyList<RemoteRepo>> ListRepos(Provider provider, string token, CancellationToken cancel = default)
    {
        var baseUrl = provider == Provider.GITHUB
            ? "https://api.github.com/user/repos?sort=updated&affiliation=owner,collaborator,organization_member"
            : "https://gitee.com/api/v5/user/repos?sort=updated&type=all";
        var repos = new List<RemoteRepo>();
        for (var page = 1; page <= MaxPages; page++)
        {
            var json = await Request(provider, token, HttpMethod.Get, baseUrl + "&per_page=" + PageSize + "&page=" + page, null, cancel);
            if (json is not JsonElement element || element.ValueKind != JsonValueKind.Array) break;
            var batch = ParseRepos(element);
            repos.AddRange(batch);
            if (element.GetArrayLength() < PageSize) break;
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return repos.Where(repo => seen.Add(repo.CloneUrl))
            .OrderByDescending(repo => repo.IsNotebook)
            .ThenByDescending(repo => repo.UpdatedAt ?? 0)
            .ToList();
    }

    public async Task<CreatedRepo> CreatePrivateRepo(Provider provider, string token, string name, string path, CancellationToken cancel = default)
    {
        var description = NotebookMark + " " + name;
        if (provider == Provider.GITHUB)
        {
            var body = new Dictionary<string, object?>
            {
                ["name"] = path,
                ["description"] = description,
                ["private"] = true,
                ["auto_init"] = true,
                ["has_issues"] = false,
                ["has_wiki"] = false,
                ["has_projects"] = false,
            };
            var json = await Request(provider, token, HttpMethod.Post, "https://api.github.com/user/repos", body, cancel) as JsonElement?;
            if (json == null || !TryString(json.Value, "clone_url", out var clone) || !TryString(json.Value, "html_url", out var web))
                throw new SyncException(SyncErrorKind.Other, "云端返回了无法识别的内容");
            return new CreatedRepo { CloneUrl = clone, WebUrl = web };
        }
        if (provider == Provider.GITEE)
        {
            var body = new Dictionary<string, object?>
            {
                ["name"] = name,
                ["path"] = path,
                ["description"] = description,
                ["private"] = true,
                ["auto_init"] = true,
                ["has_issues"] = false,
                ["has_wiki"] = false,
            };
            var json = await Request(provider, token, HttpMethod.Post, "https://gitee.com/api/v5/user/repos", body, cancel) as JsonElement?;
            if (json == null || !TryString(json.Value, "html_url", out var html))
                throw new SyncException(SyncErrorKind.Other, "云端返回了无法识别的内容");
            var web = html.EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? html[..^4] : html;
            return new CreatedRepo { CloneUrl = web + ".git", WebUrl = web };
        }
        throw new SyncException(SyncErrorKind.Other, "这种账号不能在这里新建笔记本");
    }

    public static IReadOnlyList<RemoteRepo> ParseRepos(JsonElement array)
    {
        var repos = new List<RemoteRepo>();
        foreach (var repo in array.EnumerateArray())
        {
            if (!TryString(repo, "html_url", out var web)) continue;
            if (web.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) web = web[..^4];
            var path = TryString(repo, "path", out var pathValue) ? pathValue
                : TryString(repo, "name", out var nameValue) ? nameValue
                : web.Split('/').Last();
            var description = TryString(repo, "description", out var described) ? described : "";
            var marked = description.StartsWith(NotebookMark, StringComparison.Ordinal);
            var owner = OwnerOf(repo, web);
            long? updated = null;
            if ((TryString(repo, "pushed_at", out var pushed) || TryString(repo, "updated_at", out pushed)) &&
                DateTimeOffset.TryParse(pushed, out var when))
                updated = when.ToUnixTimeMilliseconds();
            long? size = repo.TryGetProperty("size", out var sizeElement) && sizeElement.ValueKind == JsonValueKind.Number && sizeElement.TryGetInt64(out var sizeValue)
                ? sizeValue : null;
            var isPrivate = !repo.TryGetProperty("private", out var privateElement) || privateElement.ValueKind != JsonValueKind.False;
            repos.Add(new RemoteRepo
            {
                Path = path,
                DisplayName = marked ? description[NotebookMark.Length..].Trim() : TryString(repo, "name", out var display) ? display : path,
                CloneUrl = TryString(repo, "clone_url", out var clone) ? clone : web + ".git",
                IsNotebook = marked,
                IsPrivate = isPrivate,
                Owner = owner,
                UpdatedAt = updated,
                SizeKb = size,
            });
        }
        return repos;
    }

    static string OwnerOf(JsonElement repo, string web)
    {
        if (repo.TryGetProperty("owner", out var owner) && TryString(owner, "login", out var login)) return login;
        if (repo.TryGetProperty("namespace", out var ns) && TryString(ns, "path", out var path)) return path;
        var parts = web.Split('/');
        return parts.Length >= 2 ? parts[^2] : "";
    }

    static bool TryString(JsonElement element, string name, out string value)
    {
        value = "";
        if (!element.TryGetProperty(name, out var property)) return false;
        if (property.ValueKind == JsonValueKind.String)
        {
            value = property.GetString() ?? "";
            return true;
        }
        if (property.ValueKind == JsonValueKind.Number)
        {
            value = property.ToString();
            return true;
        }
        return false;
    }

    async Task<object?> Request(Provider provider, string token, HttpMethod method, string url, Dictionary<string, object?>? body, CancellationToken cancel)
    {
        using var client = handler == null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        client.Timeout = TimeSpan.FromSeconds(30);
        using var request = new HttpRequestMessage(method, url);
        request.Headers.UserAgent.ParseAdd(UserAgent);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(provider == Provider.GITHUB ? "application/vnd.github+json" : "application/json"));
        if (provider == Provider.GITHUB)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
        }
        else
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("token", token);
        }
        if (body != null)
            request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancel);
        }
        catch (Exception)
        {
            throw new SyncException(SyncErrorKind.Network, "网络连接失败，请检查网络后重试");
        }
        var text = await response.Content.ReadAsStringAsync(cancel);
        JsonElement? json = null;
        try
        {
            if (text.Length > 0) json = JsonDocument.Parse(text).RootElement.Clone();
        }
        catch (JsonException)
        {
            json = null;
        }
        var code = (int)response.StatusCode;
        if (code is >= 200 and < 300 && json != null) return json;
        if (code is >= 200 and < 300) throw new SyncException(SyncErrorKind.Other, "云端返回了无法识别的内容");
        var message = json is { ValueKind: JsonValueKind.Object } obj && TryString(obj, "message", out var apiMessage)
            ? apiMessage
            : text.Length > 200 ? text[..200] : text;
        switch (code)
        {
            case 401: throw new SyncException(SyncErrorKind.Auth, "令牌不对或已过期，请重新生成后粘贴");
            case 403: throw new SyncException(SyncErrorKind.Auth, "令牌缺少需要的权限，请按步骤重新生成：" + message);
            case 400 or 422:
                if (message.Contains("exist", StringComparison.OrdinalIgnoreCase) || message.Contains("已存在", StringComparison.Ordinal))
                    throw new NameTakenException();
                throw new SyncException(SyncErrorKind.Other, message);
            default: throw new SyncException(SyncErrorKind.Other, "云端请求失败（" + code + "）：" + message);
        }
    }
}

public static class RepoUrls
{
    static readonly HashSet<string> KnownHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "github.com", "www.github.com", "gitee.com", "www.gitee.com",
    };

    public static string Key(string url)
    {
        var key = url.Trim().ToLowerInvariant();
        while (key.EndsWith('/')) key = key[..^1];
        if (key.EndsWith(".git", StringComparison.Ordinal)) key = key[..^4];
        return key;
    }

    public static string ToCloneUrl(string input)
    {
        var text = input.Trim();
        while (text.EndsWith('/')) text = text[..^1];
        if (!Uri.TryCreate(text, UriKind.Absolute, out var url) || url.Host == null || !KnownHosts.Contains(url.Host))
            return text;
        var segments = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 2) return text;
        var name = segments[1].EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? segments[1][..^4] : segments[1];
        var host = url.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? url.Host[4..] : url.Host;
        return "https://" + host.ToLowerInvariant() + "/" + segments[0] + "/" + name + ".git";
    }
}

public static partial class RepoNames
{
    public static string FromName(string name)
    {
        var slug = SlugPattern().Replace(name.ToLowerInvariant(), "-").Trim('-', '.', '_');
        if (slug.Length > 60) slug = slug[..60].Trim('-', '.', '_');
        return slug.Length >= 2 && char.IsLetter(slug[0]) ? slug : "notes-" + RandomSuffix();
    }

    public static string RandomSuffix()
    {
        const string alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
        return string.Create(6, alphabet, (span, chars) =>
        {
            for (var i = 0; i < span.Length; i++) span[i] = chars[Random.Shared.Next(chars.Length)];
        });
    }

    public static bool IsValid(string path) => ValidPattern().IsMatch(path);

    [GeneratedRegex("[^a-z0-9._-]+")]
    private static partial Regex SlugPattern();

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9._-]{1,99}$")]
    private static partial Regex ValidPattern();
}
