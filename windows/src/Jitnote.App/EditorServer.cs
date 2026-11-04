using System.Net;

namespace Jitnote;

/// <summary>
/// Serves the shared editor and the open notebook to the page. A path that leaves the notebook,
/// or that steps into .git, is refused. The page never receives a rewritten image reference.
/// </summary>
public sealed class EditorServer : IDisposable
{
    readonly HttpListener listener = new();
    readonly string editorRoot;
    readonly CancellationTokenSource stop = new();
    string? notebookRoot;

    public int Port { get; }

    public EditorServer(string editorRoot)
    {
        this.editorRoot = editorRoot;
        // HttpListener cannot ask the OS for a free port, so walk a short private range.
        for (var port = 47321; port < 47421; port++)
        {
            try
            {
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
                listener.Start();
                Port = port;
                _ = Task.Run(Loop);
                return;
            }
            catch (HttpListenerException)
            {
                listener.Prefixes.Clear();
            }
        }
        throw new InvalidOperationException("没有可用的本地端口来打开编辑器。");
    }

    public void SetNotebook(string? root) => notebookRoot = root;

    public string EditorUrl => "http://127.0.0.1:" + Port + "/editor/index.html";

    public string NotebookUrl(string relative) =>
        "http://127.0.0.1:" + Port + "/notebook/" + relative.Replace('\\', '/');

    async Task Loop()
    {
        while (!stop.IsCancellationRequested)
        {
            HttpListenerContext context;
            try { context = await listener.GetContextAsync(); }
            catch { return; }
            try { Serve(context); }
            catch
            {
                try { context.Response.StatusCode = 500; context.Response.Close(); } catch { /* already closed */ }
            }
        }
    }

    void Serve(HttpListenerContext context)
    {
        var path = Uri.UnescapeDataString(context.Request.Url?.AbsolutePath ?? "/");
        string? file = null;
        if (path.StartsWith("/editor/", StringComparison.Ordinal))
            file = Safe(editorRoot, path["/editor/".Length..]);
        else if (path.StartsWith("/notebook/", StringComparison.Ordinal) && notebookRoot != null)
            file = Safe(notebookRoot, path["/notebook/".Length..]);
        if (file == null || !File.Exists(file))
        {
            context.Response.StatusCode = 404;
            context.Response.Close();
            return;
        }
        var bytes = File.ReadAllBytes(file);
        context.Response.ContentType = TypeOf(file);
        context.Response.ContentLength64 = bytes.Length;
        context.Response.OutputStream.Write(bytes);
        context.Response.Close();
    }

    /// <summary>A file inside root. Null when the path escapes, or when any part is .git.</summary>
    public static string? Safe(string root, string relative)
    {
        var parts = relative.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Any(part => part == "..")) return null;
        if (parts.Any(part => part == ".git")) return null;
        var full = Path.GetFullPath(Path.Combine(root, string.Join(Path.DirectorySeparatorChar, parts)));
        var baseFull = Path.GetFullPath(root);
        if (!baseFull.EndsWith(Path.DirectorySeparatorChar)) baseFull += Path.DirectorySeparatorChar;
        return full.StartsWith(baseFull, StringComparison.Ordinal) ? full : null;
    }

    static string TypeOf(string file) => Path.GetExtension(file).ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".svg" => "image/svg+xml",
        ".bmp" => "image/bmp",
        _ => "application/octet-stream",
    };

    public void Dispose()
    {
        stop.Cancel();
        try { listener.Stop(); } catch { /* stopping */ }
        listener.Close();
    }
}

/// <summary>The script the page runs before its own modules, so JitnoteHost exists when the editor loads.</summary>
public static class EditorShim
{
    public static string Script { get; } = """
        window.JitnoteHost = {
          onReady: function () {
            window.chrome.webview.postMessage(JSON.stringify({ type: 'ready' }));
          },
          onChange: function (markdown) {
            window.chrome.webview.postMessage(JSON.stringify({ type: 'change', markdown: markdown }));
          },
          resolveFile: function (path) {
            try {
              var found = window.chrome.webview.hostObjects.sync.jitnote.ResolveFile(path);
              return found || '';
            } catch (e) { return ''; }
          },
          openImage: function (path) {
            window.chrome.webview.postMessage(JSON.stringify({ type: 'image', path: path }));
          }
        };
        """;

    public static string LoadCall(string markdownJson, bool readOnly, string baseUrl, string notebookUrl) =>
        "window.JitnoteEditor && window.JitnoteEditor.load(" + markdownJson + ",{readonly:"
        + (readOnly ? "true" : "false") + ",baseUrl:" + Quote(baseUrl) + ",notebookUrl:" + Quote(notebookUrl) + "})";

    public static string Quote(string text) => Json(text);

    public static string Json(string text) => System.Text.Json.JsonSerializer.Serialize(text);
}
