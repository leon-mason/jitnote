using Avalonia.Controls;
using Avalonia.Layout;

namespace Jitnote;

/// <summary>One heading in the preview outline. Level is 1–6.</summary>
public sealed record OutlineHeading(int Level, string Text);

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
    /// <summary>Null while the note is not ready. An empty list means there are no headings. design.md 「编辑器」.</summary>
    Task<IReadOnlyList<OutlineHeading>?> HeadingsAsync();
    /// <summary>Scrolls to a heading from <see cref="HeadingsAsync"/>. Does not change the note.</summary>
    void ScrollToHeading(int index);
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

    public Task<IReadOnlyList<OutlineHeading>?> HeadingsAsync()
    {
        if (!box.IsVisible) return Task.FromResult<IReadOnlyList<OutlineHeading>?>(null);
        IReadOnlyList<OutlineHeading> list = FindHeadings(box.Text ?? "")
            .Select(item => new OutlineHeading(item.Level, item.Text))
            .ToList();
        return Task.FromResult<IReadOnlyList<OutlineHeading>?>(list);
    }

    public void ScrollToHeading(int index)
    {
        var found = FindHeadings(box.Text ?? "");
        if (index < 0 || index >= found.Count) return;
        box.SelectionStart = found[index].Offset;
        box.SelectionEnd = found[index].Offset;
    }

    readonly record struct FoundHeading(int Level, string Text, int Offset);

    /// <summary>
    /// ATX headings for the text box that stands in when the shared editor is unavailable.
    /// The preview in the real editor reads headings from that page instead (editor/src/main.js).
    /// </summary>
    static List<FoundHeading> FindHeadings(string markdown)
    {
        var list = new List<FoundHeading>();
        var text = markdown.Replace("\r\n", "\n").Replace('\r', '\n');
        var lines = text.Split('\n');
        var offset = 0;
        var fence = false;
        var front = lines.Length > 0 && lines[0].Trim() == "---";
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var next = offset + line.Length + 1;
            if (front)
            {
                if (i > 0 && line.Trim() == "---") front = false;
                offset = next;
                continue;
            }
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
                fence = !fence;
            else if (!fence)
            {
                var marks = 0;
                while (marks < trimmed.Length && marks < 6 && trimmed[marks] == '#') marks++;
                if (marks > 0 && marks < trimmed.Length && trimmed[marks] == ' ')
                {
                    var body = trimmed[(marks + 1)..].Trim().TrimEnd('#').Trim();
                    list.Add(new FoundHeading(marks, body, offset));
                }
            }
            offset = next;
        }
        return list;
    }
}
