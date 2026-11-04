using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media.Imaging;

namespace Jitnote;

/// <summary>
/// The note on the right. On this Mac the shared editor's WebView2 host is not available, so a text box
/// stands in and still obeys the save rule: nothing is written until the text really changes.
/// The Windows package uses <see cref="WebNoteSurface"/> when that symbol is compiled in.
/// </summary>
public interface INoteSurface
{
    void ShowText(string text, bool readOnly);
    void ShowImage(string file);
    void ShowMessage(string message);
    void SetBusy(bool busy);
    string? CurrentText { get; }
    event Action<string>? TextEdited;
}

public sealed class TextNoteSurface : UserControl, INoteSurface
{
    readonly TextBox box = new()
    {
        AcceptsReturn = true,
        TextWrapping = Avalonia.Media.TextWrapping.Wrap,
    };
    readonly Image image = new() { Stretch = Avalonia.Media.Stretch.Uniform };
    readonly TextBlock message = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        TextWrapping = Avalonia.Media.TextWrapping.Wrap,
        Margin = new Avalonia.Thickness(24),
    };
    readonly Grid root = new();
    bool loading;
    bool busy;
    bool userReadOnly;

    public TextNoteSurface()
    {
        box.TextChanged += (_, _) =>
        {
            if (!loading) TextEdited?.Invoke(box.Text ?? "");
        };
        root.Children.Add(box);
        root.Children.Add(image);
        root.Children.Add(message);
        Content = root;
        ShowMessage("打开左边的一篇笔记");
    }

    public string? CurrentText => box.IsVisible ? box.Text : null;

    public event Action<string>? TextEdited;

    public void SetBusy(bool busy)
    {
        this.busy = busy;
        box.IsReadOnly = busy || userReadOnly;
    }

    public void ShowText(string text, bool readOnly)
    {
        loading = true;
        userReadOnly = readOnly;
        box.Text = text;
        box.IsReadOnly = busy || readOnly;
        loading = false;
        box.IsVisible = true;
        image.IsVisible = false;
        message.IsVisible = false;
    }

    public void ShowImage(string file)
    {
        image.Source = new Bitmap(file);
        box.IsVisible = false;
        image.IsVisible = true;
        message.IsVisible = false;
    }

    public void ShowMessage(string text)
    {
        message.Text = text;
        box.IsVisible = false;
        image.IsVisible = false;
        message.IsVisible = true;
    }
}
