#if JITNOTE_WEBVIEW2
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Platform;
using Microsoft.Web.WebView2.Core;

namespace Jitnote;

/// <summary>
/// Windows 11 editor host. The shim is injected before the page's own modules, and Ctrl+E is taken
/// in AcceleratorKeyPressed because the editor itself binds that key to inline code.
/// </summary>
public sealed class WebNoteSurface : NativeControlHost, INoteSurface
{
    readonly Session session;
    readonly EditorServer server;
    readonly ResolveBridge bridge;
    CoreWebView2Controller? controller;
    bool readOnly;
    string pending = "";
    // False from ShowText until that load() has run, so a heading read does not return the previous note.
    bool headingsReady;
    int loadGeneration;

    public WebNoteSurface(Session session, string editorRoot)
    {
        this.session = session;
        server = new EditorServer(editorRoot);
        bridge = new ResolveBridge(path =>
        {
            var full = session.ResolveReference(path);
            if (full == null) return "";
            var root = session.Current == null ? "" : session.FolderOf(session.Current);
            // Relative, not a URL: the editor adds its notebookUrl, and hands this same path back on a tap.
            return root.Length == 0 ? "" : Path.GetRelativePath(root, full).Replace('\\', '/');
        });
        SizeChanged += (_, _) => Fit();
    }

    public string? CurrentText { get; private set; }
    public event Action<string>? TextEdited;
    public event Action<string>? ImageTapped;

    public void ShowText(string text, bool readOnly)
    {
        CurrentText = text;
        this.readOnly = readOnly;
        pending = text;
        loadGeneration++;
        headingsReady = false;
        if (session.Current != null) server.SetNotebook(session.FolderOf(session.Current));
        if (controller == null) return;
        _ = Load(text);
    }

    public void ReleaseKeyboard()
    {
        // Hiding a window that holds the focus does not move it, so hand it to the main window ourselves.
        var window = TopLevel.GetTopLevel(this)?.TryGetPlatformHandle()?.Handle;
        if (window != null) SetFocus(window.Value);
    }

    public void TakeKeyboard() => controller?.MoveFocus(CoreWebView2MoveFocusReason.Programmatic);

    public void ShowMessage(string message)
    {
        CurrentText = null;
        pending = "";
    }

    public void SetBusy(bool busy)
    {
        if (controller == null) return;
        _ = controller.CoreWebView2.ExecuteScriptAsync(
            "window.JitnoteEditor && window.JitnoteEditor.setReadonly(" + (busy || readOnly ? "true" : "false") + ")");
    }

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        var hwnd = CreateWindowEx(0, "static", "", WsChild | WsVisible, 0, 0, 100, 100,
            parent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _ = Start(hwnd);
        return new PlatformHandle(hwnd, "HWND");
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        controller?.Close();
        controller = null;
        server.Dispose();
        DestroyWindow(control.Handle);
    }

    async Task Start(IntPtr hwnd)
    {
        // WebView2 defaults its data folder to "<exe>.WebView2" next to the exe. The app is now a single exe
        // people drop anywhere (Downloads, a read-only folder), so keep that folder with the app's own data.
        var environment = await CoreWebView2Environment.CreateAsync(
            null, Path.Combine(Session.DefaultDirectory(), "WebView2"));
        var created = await environment.CreateCoreWebView2ControllerAsync(hwnd);
        controller = created;
        var web = created.CoreWebView2;
        await web.AddScriptToExecuteOnDocumentCreatedAsync(EditorShim.Script);
        web.AddHostObjectToScript("jitnote", bridge);
        web.WebMessageReceived += (_, args) => OnMessage(args.TryGetWebMessageAsString());
        created.AcceleratorKeyPressed += (_, args) => OnAccelerator(args);
        web.Navigate(server.EditorUrl);
        Fit();
    }

    void OnMessage(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var type = document.RootElement.GetProperty("type").GetString();
            if (type == "ready")
            {
                if (pending.Length > 0 || CurrentText != null) _ = Load(pending);
            }
            else if (type == "change" && document.RootElement.TryGetProperty("markdown", out var markdown))
            {
                var text = markdown.GetString() ?? "";
                CurrentText = text;
                TextEdited?.Invoke(text);
            }
            else if (type == "image" && document.RootElement.TryGetProperty("path", out var path))
            {
                var tapped = path.GetString();
                if (!string.IsNullOrEmpty(tapped))
                    Avalonia.Threading.Dispatcher.UIThread.Post(() => ImageTapped?.Invoke(tapped));
            }
        }
        catch { /* a message that is not ours is ignored */ }
    }

    async Task Load(string text)
    {
        if (controller == null) return;
        var generation = loadGeneration;
        var folder = session.OpenPath == null ? "" : FileTree.Parent(session.OpenPath);
        var script = EditorShim.LoadCall(
            EditorShim.Json(text),
            readOnly,
            server.NotebookUrl(folder.Length == 0 ? "" : folder + "/"),
            server.NotebookUrl(""));
        await controller.CoreWebView2.ExecuteScriptAsync(script);
        // A newer ShowText owns the page. The page's own load() may still be running;
        // headings() stays null until that finishes, and HeadingsAsync retries.
        if (generation == loadGeneration) headingsReady = true;
    }

    /// <summary>
    /// Ctrl+E must be handled here: once the page sees it, the editor turns it into inline code.
    /// The other shortcuts are handled too, so a focused editor does not swallow them.
    /// </summary>
    void OnAccelerator(CoreWebView2AcceleratorKeyPressedEventArgs args)
    {
        if (args.KeyEventKind != CoreWebView2KeyEventKind.KeyDown && args.KeyEventKind != CoreWebView2KeyEventKind.SystemKeyDown)
            return;
        var ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;
        var shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
        if (!ctrl) return;
        var key = args.VirtualKey;
        if (key is 0x45 or 0x4E or 0x52 or 0xBC)
        {
            args.Handled = true;
            Avalonia.Threading.Dispatcher.UIThread.Post(() => Shortcut?.Invoke(key, shift));
        }
    }

    public event Action<uint, bool>? Shortcut;

    public async Task<IReadOnlyList<OutlineHeading>?> HeadingsAsync()
    {
        if (!headingsReady || controller == null) return null;
        try
        {
            // Null until load() has created the editor. An empty array means the note has no headings.
            var raw = await controller.CoreWebView2.ExecuteScriptAsync(
                "window.JitnoteEditor && window.JitnoteEditor.headings ? window.JitnoteEditor.headings() : null");
            return ParseHeadings(raw);
        }
        catch
        {
            return null;
        }
    }

    public void ScrollToHeading(int index)
    {
        if (index < 0 || controller == null) return;
        _ = controller.CoreWebView2.ExecuteScriptAsync(
            "window.JitnoteEditor && window.JitnoteEditor.scrollToHeading(" + index + ")");
    }

    static IReadOnlyList<OutlineHeading>? ParseHeadings(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw) || raw == "null") return null;
        try
        {
            using var document = JsonDocument.Parse(raw);
            if (document.RootElement.ValueKind != JsonValueKind.Array) return null;
            var list = new List<OutlineHeading>();
            foreach (var item in document.RootElement.EnumerateArray())
            {
                var level = item.TryGetProperty("level", out var levelValue) ? levelValue.GetInt32() : 1;
                var text = item.TryGetProperty("text", out var textValue) ? textValue.GetString() ?? "" : "";
                list.Add(new OutlineHeading(level, text));
            }
            return list;
        }
        catch
        {
            return null;
        }
    }

    void Fit()
    {
        if (controller == null) return;
        controller.Bounds = new System.Drawing.Rectangle(0, 0, Math.Max(1, (int)Bounds.Width), Math.Max(1, (int)Bounds.Height));
    }

    const int WsChild = 0x40000000;
    const int WsVisible = 0x10000000;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    static extern IntPtr SetFocus(IntPtr hwnd);

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int key);
}

/// <summary>Answers resolveFile on the page's thread. A path outside the notebook comes back empty.</summary>
[ComVisible(true)]
public sealed class ResolveBridge
{
    readonly Func<string, string> resolve;
    public ResolveBridge(Func<string, string> resolve) => this.resolve = resolve;
    public string ResolveFile(string path) => resolve(path) ?? "";
}
#endif
