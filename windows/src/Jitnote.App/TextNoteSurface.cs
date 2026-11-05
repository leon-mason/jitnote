using Avalonia.Controls;
using Avalonia.Layout;

namespace Jitnote;

/// <summary>
/// The note on the right. On this Mac the shared editor's WebView2 host is not available, so a text box
/// stands in and still obeys the save rule: nothing is written until the text really changes.
/// The Windows package uses <see cref="WebNoteSurface"/> when that symbol is compiled in.
/// </summary>
public interface INoteSurface
{
    void ShowText(string text, bool readOnly);
    void ShowMessage(string message);
    void SetBusy(bool busy);
    string? CurrentText { get; }
    /// <summary>Gives up the keyboard while a picture covers the note.</summary>
    void ReleaseKeyboard();
    /// <summary>Takes the keyboard back, with the cursor where it was.</summary>
    void TakeKeyboard();
    event Action<string>? TextEdited;
    /// <summary>A picture was tapped in the note; the path is relative to the notebook.</summary>
    event Action<string>? ImageTapped;
}

public sealed class TextNoteSurface : UserControl, INoteSurface
{
    readonly TextBox box = new()
    {
        AcceptsReturn = true,
        TextWrapping = Avalonia.Media.TextWrapping.Wrap,
    };
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
        root.Children.Add(message);
        Content = root;
        ShowMessage("打开左边的一篇笔记");
    }

    public string? CurrentText => box.IsVisible ? box.Text : null;

    public event Action<string>? TextEdited;

    // A text box shows no pictures, so none can be tapped.
    public event Action<string>? ImageTapped { add { } remove { } }

    public void ReleaseKeyboard() { }

    public void TakeKeyboard() => box.Focus();

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
        message.IsVisible = false;
    }

    public void ShowMessage(string text)
    {
        message.Text = text;
        box.IsVisible = false;
        message.IsVisible = true;
    }
}
