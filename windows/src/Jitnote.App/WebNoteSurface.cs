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

    public WebNoteSurface(Session session, string editorRoot)
    {
        this.session = session;
        server = new EditorServer(editorRoot);
        bridge = new ResolveBridge(path =>
        {
            var full = session.ResolveReference(path);
            if (full == null) return "";
            var root = session.Current == null ? "" : session.FolderOf(session.Current);
            var relative = root.Length == 0 ? "" : Path.GetRelativePath(root, full).Replace('\\', '/');
            return relative.Length == 0 ? "" : server.NotebookUrl(relative);
        });
        SizeChanged += (_, _) => Fit();
    }

    public string? CurrentText { get; private set; }
    public event Action<string>? TextEdited;

    public void ShowText(string text, bool readOnly)
    {
        CurrentText = text;
        this.readOnly = readOnly;
        pending = text;
        if (session.Current != null) server.SetNotebook(session.FolderOf(session.Current));
        if (controller == null) return;
        _ = Load(text);
    }

    public void ShowImage(string file)
    {
        CurrentText = null;
        if (session.Current == null || controller == null) return;
        var root = session.FolderOf(session.Current);
        server.SetNotebook(root);
        var relative = Path.GetRelativePath(root, file).Replace('\\', '/');
        controller.CoreWebView2.Navigate(server.NotebookUrl(relative));
    }

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
        var environment = await CoreWebView2Environment.CreateAsync();
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
        }
        catch { /* a message that is not ours is ignored */ }
    }

    async Task Load(string text)
    {
        if (controller == null) return;
        var folder = session.OpenPath == null ? "" : FileTree.Parent(session.OpenPath);
        var script = EditorShim.LoadCall(
            EditorShim.Json(text),
            readOnly,
            server.NotebookUrl(folder.Length == 0 ? "" : folder + "/"),
            server.NotebookUrl(""));
        await controller.CoreWebView2.ExecuteScriptAsync(script);
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
