namespace Jitnote;

/// <summary>
/// Where a notebook lives, and which folders may become one (design.md, 「笔记本文件夹」).
/// The place is chosen only when the notebook is created.
/// </summary>
public static class NotebookFolders
{
    // Finder and Explorer leave these behind. They do not count as content. .DS_Store is included so a
    // folder copied from a Mac is still empty; desktop.ini and Thumbs.db are what Windows itself writes.
    static readonly HashSet<string> Ignored = new(StringComparer.OrdinalIgnoreCase) { ".DS_Store", "desktop.ini", "Thumbs.db" };

    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Jitnote");

    public static string DefaultFolder(string name, string? root = null)
    {
        root ??= DefaultRoot;
        var baseName = FolderName(name);
        for (var number = 1; number <= 1000; number++)
        {
            var candidate = Path.Combine(root, number == 1 ? baseName : baseName + " " + number);
            if (IsEmptyOrMissing(candidate)) return candidate;
        }
        return Path.Combine(root, baseName + " " + Guid.NewGuid().ToString("n")[..8]);
    }

    public static bool IsInDefaultRoot(string folder, string? root = null)
    {
        root ??= DefaultRoot;
        return Canonical(Path.GetDirectoryName(folder) ?? "") == Canonical(root);
    }

    public static string? Problem(string folder, IReadOnlyList<string>? otherNotebooks = null)
    {
        if (File.Exists(folder) && !Directory.Exists(folder)) return "这个位置是一个文件，不是文件夹。";
        if (Directory.Exists(folder))
        {
            string[] items;
            try
            {
                items = Directory.GetFileSystemEntries(folder).Select(Path.GetFileName).ToArray()!;
            }
            catch (Exception)
            {
                return "没有权限使用这个文件夹。";
            }
            if (items.Any(item => !Ignored.Contains(item!)))
                return "这个文件夹不是空的。请选一个空文件夹，或者在选择窗口里点「新建文件夹」。";
        }
        var path = Canonical(folder);
        foreach (var other in (otherNotebooks ?? Array.Empty<string>()).Select(Canonical))
        {
            if (path == other || path.StartsWith(other + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                return "这个文件夹在另一个笔记本里面。";
        }
        return null;
    }

    public static bool IsMissing(string folder)
    {
        if (!Directory.Exists(folder)) return true;
        return !Directory.Exists(Path.Combine(folder, ".git"));
    }

    public static string? RelocationProblem(string folder, string? originUrl, string expectedRemote, IReadOnlyList<string> otherNotebooks)
    {
        if (IsMissing(folder)) return "这个文件夹里没有笔记本。";
        if (originUrl == null || RepoUrls.Key(originUrl) != RepoUrls.Key(expectedRemote))
            return "这个文件夹里是另一个笔记本，不是这一个。";
        var path = Canonical(folder);
        if (otherNotebooks.Select(Canonical).Contains(path)) return "这个文件夹已经是另一个笔记本在用了。";
        return null;
    }

    public static string? RedownloadProblem(string target, bool mayCreateParents)
    {
        var problem = Problem(target);
        if (problem != null) return problem;
        var parent = Path.GetDirectoryName(target) ?? "";
        if (!mayCreateParents && !Directory.Exists(parent))
            return "放这个笔记本的位置「" + parent + "」也找不到，可能是外置硬盘没有插上。";
        return null;
    }

    public static string? SyncWarning(string folder)
    {
        var parts = Canonical(folder).Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        var synced = parts.Any(part =>
            part is "Mobile Documents" or "CloudStorage" or "com~apple~CloudDocs" or "iCloud Drive"
            || part.StartsWith("Dropbox", StringComparison.Ordinal)
            || part.StartsWith("OneDrive", StringComparison.Ordinal)
            || part.StartsWith("Google Drive", StringComparison.Ordinal));
        return synced
            ? "这个位置会被 iCloud 云盘或网盘同步。它们和笔记本自己的同步会互相干扰，可能弄坏笔记本里的版本记录。建议换一个不会被同步的位置。"
            : null;
    }

    public static string FolderName(string name)
    {
        var cleaned = name.Trim().Replace('/', '-').Replace(':', '-').Replace('\\', '-');
        while (cleaned.StartsWith('.')) cleaned = cleaned[1..];
        return cleaned.Length == 0 ? "笔记本" : cleaned;
    }

    static bool IsEmptyOrMissing(string folder) => !Directory.Exists(folder) || Problem(folder) == null;

    public static string Canonical(string path)
    {
        var full = Path.GetFullPath(path);
        try
        {
            if (Directory.Exists(full) || File.Exists(full))
                return NoteIndex.Real(full).TrimEnd(Path.DirectorySeparatorChar);
        }
        catch (IOException)
        {
        }
        return full.TrimEnd(Path.DirectorySeparatorChar);
    }
}
