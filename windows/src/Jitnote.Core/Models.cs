using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jitnote;

public enum Provider
{
    GITHUB,
    GITEE,
    OTHER,
}

public static class ProviderLabels
{
    public static string Label(this Provider provider) => provider switch
    {
        Provider.GITHUB => "GitHub",
        Provider.GITEE => "Gitee",
        _ => "其他",
    };

    public static bool CanCreateRepos(this Provider provider) => provider != Provider.OTHER;
}

/// <summary>A connected cloud account. The token is not in this object.</summary>
public sealed class Account
{
    public string Id { get; set; } = "";
    public Provider Provider { get; set; }
    public string Login { get; set; } = "";
    public string Email { get; set; } = "";
    public long CreatedAt { get; set; }

    public override string ToString() => Provider.Label() + " · " + Login;
}

public sealed class Notebook
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string AccountId { get; set; } = "";
    public string RemoteUrl { get; set; } = "";
    public string Dir { get; set; } = "";
    public long CreatedAt { get; set; }
    public long? LastSyncAt { get; set; }
    public string? LastSyncError { get; set; }
    /// <summary>Absolute folder. Null for notebooks saved before folders were chosen.</summary>
    public string? FolderPath { get; set; }
    /// <summary>The user picked this place. Removing the notebook then leaves the folder alone.</summary>
    public bool FolderChosen { get; set; }

    public override string ToString() => Name;
}

public enum NoteSort
{
    MODIFIED_DESC,
    MODIFIED_ASC,
    TITLE_ASC,
    TITLE_DESC,
}

public enum ViewMode
{
    EDIT,
    PREVIEW,
}

/// <summary>The app's own small state. Same fields as Mac and Android, and never the token.</summary>
public sealed class AppState
{
    public List<Account> Accounts { get; set; } = new();
    public List<Notebook> Notebooks { get; set; } = new();
    public string? CurrentNotebookId { get; set; }
    public NoteSort FileSort { get; set; } = NoteSort.TITLE_ASC;
    public Dictionary<string, HashSet<string>> ExpandedFolders { get; set; } = new();
    public ViewMode DefaultViewMode { get; set; } = ViewMode.EDIT;
    public bool ShowHiddenFiles { get; set; }
    public long? LastUpdateCheckAt { get; set; }

    public Notebook? CurrentNotebook =>
        Notebooks.FirstOrDefault(notebook => notebook.Id == CurrentNotebookId) ?? Notebooks.FirstOrDefault();
}

public static class AppJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters = { new JsonStringEnumConverter() },
        WriteIndented = true,
    };

    public static long NowMillis() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}
