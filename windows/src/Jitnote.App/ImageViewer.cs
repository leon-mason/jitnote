using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace Jitnote;

/// <summary>
/// A picture from the notebook inside the note pane, with its zoom controls. It only displays the file;
/// whether the open note stays underneath is decided by <see cref="MainWindow"/>.
/// </summary>
public sealed class ImageViewer : UserControl
{
    // The same limits as the Mac viewer: 8x reads a screenshot's small print, further only shows pixels.
    const double Largest = 8;
    const double Smallest = 0.25;
    const double Step = 1.5;

    readonly Button back = new() { Content = "返回" };
    readonly TextBlock name = new() { FontSize = 16, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly Button percent = new() { MinWidth = 64, HorizontalContentAlignment = HorizontalAlignment.Center };
    readonly Image image = new()
    {
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly TextBlock failed = new()
    {
        Text = "这张图片打不开",
        Opacity = 0.7,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly ScrollViewer scroller = new()
    {
        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
    };

    string? file;
    DateTime stamp;
    Bitmap? bitmap;
    /// <summary>Null means "fit the pane", which also follows the window as it resizes.</summary>
    double? chosenScale;

    public event Action? BackRequested;

    public ImageViewer()
    {
        var zoomOut = new Button { Content = "缩小" };
        var zoomIn = new Button { Content = "放大" };
        zoomOut.Click += (_, _) => ZoomTo(Scale / Step);
        zoomIn.Click += (_, _) => ZoomTo(Scale * Step);
        percent.Click += (_, _) => FitToPane();
        back.Click += (_, _) => BackRequested?.Invoke();
        ToolTip.SetTip(back, "返回（Esc）");
        ToolTip.SetTip(zoomOut, "缩小（Ctrl+-）");
        ToolTip.SetTip(percent, "适合窗口（Ctrl+0）");
        ToolTip.SetTip(zoomIn, "放大（Ctrl+=）");

        var zoom = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        zoom.Children.Add(zoomOut);
        zoom.Children.Add(percent);
        zoom.Children.Add(zoomIn);
        DockPanel.SetDock(zoom, Dock.Right);
        DockPanel.SetDock(back, Dock.Left);
        back.Margin = new Thickness(0, 0, 8, 0);
        var header = new DockPanel { Margin = new Thickness(8, 0, 8, 8) };
        header.Children.Add(back);
        header.Children.Add(zoom);
        header.Children.Add(name);
        DockPanel.SetDock(header, Dock.Top);

        scroller.Content = image;
        scroller.SizeChanged += (_, _) => Apply();
        var body = new Grid();
        body.Children.Add(scroller);
        body.Children.Add(failed);
        var root = new DockPanel();
        root.Children.Add(header);
        root.Children.Add(body);
        Content = root;

        // A precision touchpad's pinch reaches a Windows app as Ctrl+wheel. Tunnel: the scroller would take it first.
        AddHandler(PointerWheelChangedEvent, (_, e) =>
        {
            if (!e.KeyModifiers.HasFlag(KeyModifiers.Control)) return;
            e.Handled = true;
            ZoomTo(Scale * Math.Pow(Step, e.Delta.Y));
        }, RoutingStrategies.Tunnel);
    }

    /// <summary>
    /// Shows [path]. Called on every window refresh, so the same unchanged file keeps its zoom and scroll,
    /// and is read again only when another program replaced it.
    /// </summary>
    public void Show(string path, bool canGoBack, bool showName)
    {
        back.IsVisible = canGoBack;
        name.IsVisible = showName;
        name.Text = Path.GetFileName(path);
        var written = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : default;
        if (path == file && written == stamp) return;
        if (path != file) chosenScale = null;
        file = path;
        stamp = written;
        Load(path);
    }

    /// <summary>Lets go of the picture, so a large one is not held in memory while hidden.</summary>
    public void Clear()
    {
        file = null;
        image.Source = null;
        bitmap?.Dispose();
        bitmap = null;
        chosenScale = null;
    }

    /// <summary>Esc and the zoom keys. Returns whether the key was one of them.</summary>
    public bool HandleKey(KeyEventArgs e)
    {
        if (e.Key == Key.Escape && e.KeyModifiers == KeyModifiers.None && back.IsVisible)
        {
            BackRequested?.Invoke();
            return true;
        }
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control)) return false;
        switch (e.Key)
        {
            case Key.OemPlus or Key.Add:
                ZoomTo(Scale * Step);
                return true;
            case Key.OemMinus or Key.Subtract:
                ZoomTo(Scale / Step);
                return true;
            case Key.D0 or Key.NumPad0:
                FitToPane();
                return true;
            default:
                return false;
        }
    }

    void Load(string path)
    {
        var old = bitmap;
        try
        {
            bitmap = new Bitmap(path);
        }
        catch (Exception)
        {
            // Deleted meanwhile, damaged, or a kind the graphics library cannot decode (HEIC, AVIF, SVG).
            bitmap = null;
        }
        image.Source = bitmap;
        old?.Dispose();
        failed.IsVisible = bitmap == null;
        scroller.IsVisible = bitmap != null;
        Apply();
    }

    /// <summary>Never enlarges a small picture past its own size until asked to.</summary>
    double FitScale
    {
        get
        {
            var pane = scroller.Bounds.Size;
            if (bitmap == null || bitmap.Size.Width <= 0 || bitmap.Size.Height <= 0 || pane.Width <= 0 || pane.Height <= 0) return 1;
            return Math.Min(1, Math.Min(pane.Width / bitmap.Size.Width, pane.Height / bitmap.Size.Height));
        }
    }

    double Scale => chosenScale ?? FitScale;

    void ZoomTo(double scale)
    {
        // A huge picture fits at less than the usual minimum; it must still be able to get back there.
        chosenScale = Math.Min(Largest, Math.Max(Math.Min(Smallest, FitScale), scale));
        Apply();
    }

    void FitToPane()
    {
        chosenScale = null;
        Apply();
    }

    void Apply()
    {
        percent.Content = Math.Round(Scale * 100) + "%";
        if (bitmap == null) return;
        // Rounded down: a fraction of a pixel over the pane would bring up both scroll bars.
        image.Width = Math.Floor(bitmap.Size.Width * Scale);
        image.Height = Math.Floor(bitmap.Size.Height * Scale);
    }
}
