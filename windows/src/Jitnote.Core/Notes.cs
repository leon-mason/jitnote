using System.Globalization;
using System.Text;

namespace Jitnote;

public sealed class NoteEntry
{
    public required string Path { get; init; }
    public required string Name { get; init; }
    public required bool IsFolder { get; init; }
    public required IReadOnlyList<NoteEntry> Children { get; init; }
    public required int NoteCount { get; init; }
    public required long Modified { get; init; }
}

/// <summary>The notebook as the sidebar shows it. .git is never listed.</summary>
public static class NoteIndex
{
    public static readonly HashSet<string> NoteExtensions = new(StringComparer.OrdinalIgnoreCase) { "md", "markdown", "txt" };

    public static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "md", "markdown", "txt", "text", "json", "yml", "yaml", "toml", "csv", "tsv",
        "html", "htm", "css", "js", "ts", "kt", "java", "py", "sh", "xml", "ini", "conf", "log", "org", "rst", "tex",
    };

    public static bool IsHidden(string name, bool showHidden) =>
        name == ".git" || (!showHidden && name.StartsWith('.'));

    public static bool IsEditable(string path)
    {
        var ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return ext.Length == 0 || TextExtensions.Contains(ext);
    }

    public static IReadOnlyList<NoteEntry> Tree(string root, NoteSort sort = NoteSort.TITLE_ASC, bool showHidden = false) =>
        Entries(root, root, sort, showHidden);

    static List<NoteEntry> Entries(string dir, string root, NoteSort sort, bool showHidden)
    {
        if (!Directory.Exists(dir)) return new List<NoteEntry>();
        var items = new List<(string Path, bool IsFolder, long Modified, string Name)>();
        foreach (var path in Directory.GetFileSystemEntries(dir))
        {
            var name = System.IO.Path.GetFileName(path).Normalize(NormalizationForm.FormC);
            if (IsHidden(name, showHidden)) continue;
            var folder = Directory.Exists(path) && !File.Exists(path);
            // A symlink to a file is a file, listed under its own name.
            if (Directory.Exists(path) && File.GetAttributes(path).HasFlag(FileAttributes.Directory) && !IsReparseToFile(path))
                folder = true;
            else
                folder = Directory.Exists(path) && !IsReparseToFile(path);
            var modified = folder
                ? new DateTimeOffset(Directory.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds()
                : new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds();
            items.Add((path, folder, modified, name));
        }
        items.Sort((a, b) =>
        {
            if (a.IsFolder != b.IsFolder) return a.IsFolder ? -1 : 1;
            if (a.IsFolder) return sort == NoteSort.TITLE_DESC ? CompareTitles(b.Name, a.Name) : CompareTitles(a.Name, b.Name);
            var minuteA = a.Modified / 60_000;
            var minuteB = b.Modified / 60_000;
            switch (sort)
            {
                case NoteSort.MODIFIED_DESC when minuteA != minuteB:
                    return minuteB.CompareTo(minuteA);
                case NoteSort.MODIFIED_ASC when minuteA != minuteB:
                    return minuteA.CompareTo(minuteB);
                case NoteSort.TITLE_DESC:
                    return CompareTitles(b.Name, a.Name);
                default:
                    return CompareTitles(a.Name, b.Name);
            }
        });
        return items.Select(item =>
        {
            var children = item.IsFolder ? Entries(item.Path, root, sort, showHidden) : new List<NoteEntry>();
            return new NoteEntry
            {
                Path = Relative(root, item.Path),
                Name = item.Name,
                IsFolder = item.IsFolder,
                Children = children,
                NoteCount = item.IsFolder ? CountNotes(children) : 0,
                Modified = item.Modified,
            };
        }).ToList();
    }

    static bool IsReparseToFile(string path)
    {
        var info = new FileInfo(path);
        return info.LinkTarget != null && !Directory.Exists(path);
    }

    static int CountNotes(IReadOnlyList<NoteEntry> entries) =>
        entries.Sum(entry => entry.IsFolder
            ? entry.NoteCount
            : NoteExtensions.Contains(System.IO.Path.GetExtension(entry.Name).TrimStart('.')) ? 1 : 0);

    public static int CompareTitles(string a, string b)
    {
        // zh-CN so 甲 sorts before 乙. Digit runs compare as numbers (2 before 10).
        // CompareOptions.NumericOrdering is not in the net8.0 reference this project compiles against.
        var compare = CultureInfo.GetCultureInfo("zh-CN").CompareInfo;
        var i = 0;
        var j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                var i0 = i;
                var j0 = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var byNumber = long.Parse(a[i0..i]).CompareTo(long.Parse(b[j0..j]));
                if (byNumber != 0) return byNumber;
                continue;
            }
            var i1 = i;
            var j1 = j;
            while (i < a.Length && !char.IsDigit(a[i])) i++;
            while (j < b.Length && !char.IsDigit(b[j])) j++;
            var part = compare.Compare(a.AsSpan(i1, i - i1), b.AsSpan(j1, j - j1), CompareOptions.IgnoreCase);
            if (part != 0) return part;
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }

    /// <summary>Only parent folders are resolved, never the file itself, so a symlink keeps its own name.</summary>
    public static string Relative(string root, string path)
    {
        var rootReal = Real(root);
        var full = System.IO.Path.GetFullPath(path);
        var name = System.IO.Path.GetFileName(full);
        var parent = Real(System.IO.Path.GetDirectoryName(full)!);
        var combined = System.IO.Path.Combine(parent, name);
        var prefix = rootReal.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        if (!combined.StartsWith(prefix, StringComparison.Ordinal)) return name.Normalize(NormalizationForm.FormC);
        return combined[prefix.Length..].Replace('\\', '/').Normalize(NormalizationForm.FormC);
    }

    public static string? ResolveReference(string path, string root)
    {
        var rootReal = Real(root);
        var current = System.IO.Path.GetFullPath(path);
        var followed = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < 8; i++)
        {
            if (!seen.Add(current)) return null;
            var link = new FileInfo(current).LinkTarget;
            if (link != null)
            {
                followed = true;
                var next = LinkTarget(link, current);
                if (next == null) return null;
                current = System.IO.Path.GetFullPath(next);
                continue;
            }
            return followed ? InsideNotebook(current, rootReal) : null;
        }
        return null;
    }

    public static string? ReferenceTarget(string folder, string root, bool showHidden)
    {
        var dir = folder.Length == 0 ? root : System.IO.Path.Combine(root, folder);
        if (!Directory.Exists(dir)) return null;
        var targets = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in Directory.GetFileSystemEntries(dir))
        {
            if (IsHidden(System.IO.Path.GetFileName(item), showHidden)) continue;
            if (new FileInfo(item).LinkTarget == null) continue;
            var target = ResolveReference(item, root);
            if (target != null) targets.Add(target);
        }
        return targets.Count == 1 ? targets.First() : null;
    }

    static string? LinkTarget(string destination, string link)
    {
        var raw = destination.Trim();
        if (raw.StartsWith('@')) raw = raw[1..].Trim();
        while (raw.StartsWith("./", StringComparison.Ordinal)) raw = raw[2..];
        if (raw.Length == 0 || raw.Contains("://", StringComparison.Ordinal) || raw.Contains('\0')) return null;
        if (raw.StartsWith('/') || (raw.Length >= 3 && char.IsLetter(raw[0]) && raw[1] == ':' )) return raw;
        return System.IO.Path.Combine(System.IO.Path.GetDirectoryName(link)!, raw);
    }

    static string? InsideNotebook(string path, string rootReal)
    {
        var full = Real(System.IO.Path.GetDirectoryName(path)!) + System.IO.Path.DirectorySeparatorChar + System.IO.Path.GetFileName(path);
        var prefix = rootReal.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var relative = full[prefix.Length..].Replace('\\', '/');
        if (relative == ".git" || relative.StartsWith(".git/", StringComparison.Ordinal)) return null;
        if (!File.Exists(full) || Directory.Exists(full)) return null;
        return relative.Normalize(NormalizationForm.FormC);
    }

    public static string Real(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        try
        {
            var info = new DirectoryInfo(full);
            var target = info.ResolveLinkTarget(true);
            return target?.FullName ?? full;
        }
        catch (IOException)
        {
            return full;
        }
    }
}

public static class NoteFiles
{
    public static string? CleanName(string raw)
    {
        var name = raw.Trim().Replace('/', '-').Replace('\\', '-');
        if (name.Length == 0 || name == "." || name == ".." || name.StartsWith('.')) return null;
        return name;
    }

    public static string CreateNote(string dir, string raw)
    {
        var name = CleanName(raw) ?? throw new SyncException(SyncErrorKind.Other, "名称不能为空，也不能以 . 开头");
        var fileName = name.Contains('.') ? name : name + ".md";
        var file = System.IO.Path.Combine(dir, fileName);
        if (File.Exists(file) || Directory.Exists(file)) throw new SyncException(SyncErrorKind.Other, "已存在同名文件");
        Directory.CreateDirectory(dir);
        var body = fileName.EndsWith(".md", StringComparison.Ordinal) ? "# " + fileName[..^3] + "\n\n" : "";
        File.WriteAllText(file, body);
        return file;
    }

    public static string CreateFolder(string dir, string raw)
    {
        var name = CleanName(raw) ?? throw new SyncException(SyncErrorKind.Other, "名称不能为空，也不能以 . 开头");
        var folder = System.IO.Path.Combine(dir, name);
        if (File.Exists(folder) || Directory.Exists(folder)) throw new SyncException(SyncErrorKind.Other, "已存在同名文件夹");
        Directory.CreateDirectory(folder);
        return folder;
    }

    // Moves an item into a folder and returns where it is now. Never replaces anything: a file or folder of the
    // same name in the folder stops the move (design.md「首页」), and a folder cannot go into itself.
    public static string Move(string item, string folder)
    {
        var target = System.IO.Path.Combine(folder, System.IO.Path.GetFileName(item));
        var source = System.IO.Path.GetFullPath(item).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        if (System.IO.Path.GetFullPath(target) == source) return item;
        var destination = System.IO.Path.GetFullPath(folder).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        if (Directory.Exists(item) && (destination + System.IO.Path.DirectorySeparatorChar).StartsWith(source + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new SyncException(SyncErrorKind.Other, "不能把文件夹移动到它自己里面");
        if (File.Exists(target) || Directory.Exists(target)) throw new SyncException(SyncErrorKind.Other, "目标文件夹里已有同名文件");
        if (Directory.Exists(item)) Directory.Move(item, target);
        else File.Move(item, target);
        return target;
    }

    public static string Rename(string file, string raw)
    {
        var name = CleanName(raw) ?? throw new SyncException(SyncErrorKind.Other, "名称不能为空，也不能以 . 开头");
        var isDir = Directory.Exists(file);
        var ext = System.IO.Path.GetExtension(file);
        if (!isDir && !name.Contains('.') && ext.Length > 0) name += ext;
        var target = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(file)!, name);
        if (System.IO.Path.GetFullPath(target) == System.IO.Path.GetFullPath(file)) return file;
        if (File.Exists(target) || Directory.Exists(target)) throw new SyncException(SyncErrorKind.Other, "已存在同名文件");
        Directory.Move(file, target);
        return target;
    }
}

/// <summary>Writes a note back only after a real edit, and only when the text changed.</summary>
public sealed class NoteSaver
{
    readonly string file;
    string saved;
    bool edited;

    public NoteSaver(string file, string loaded)
    {
        this.file = file;
        saved = loaded;
    }

    public void MarkEdited() => edited = true;

    public bool Save(string? text)
    {
        if (!edited || text == null || text == saved) return false;
        // The note is gone. Writing it back would recreate a file nobody asked for.
        if (!File.Exists(file)) return false;
        var temp = file + ".sb-" + Guid.NewGuid().ToString("n");
        File.WriteAllText(temp, text);
        File.Move(temp, file, true);
        saved = text;
        return true;
    }

    public bool ChangedOnDisk(string disk) => disk != saved;

    public void Adopt(string disk)
    {
        saved = disk;
        edited = false;
    }
}

/// <summary>
/// Finds the file a note refers to. Never resolves outside the notebook or into .git.
/// Display only: callers must not rewrite the reference in the note.
/// </summary>
public sealed class NoteAssets
{
    public static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif", "svg",
    };

    readonly string root;
    readonly string rootReal;
    readonly Lazy<Dictionary<string, List<string>>> byName;

    public NoteAssets(string root)
    {
        this.root = root;
        rootReal = NoteIndex.Real(root);
        byName = new Lazy<Dictionary<string, List<string>>>(Index);
    }

    public static bool IsImage(string path) =>
        ImageExtensions.Contains(System.IO.Path.GetExtension(path).TrimStart('.'));

    public string? Resolve(string noteFolder, string reference)
    {
        var path = reference.Trim();
        if (path.StartsWith("./", StringComparison.Ordinal)) path = path[2..];
        if (path.Length == 0 || path.Contains("://", StringComparison.Ordinal)) return null;
        var candidates = path.StartsWith('/')
            ? new[] { path.TrimStart('/') }
            : new[] { noteFolder.Length == 0 ? path : noteFolder + "/" + path, path };
        foreach (var candidate in candidates)
        {
            var found = Existing(candidate);
            if (found != null) return found;
        }
        var wanted = "/" + path.TrimStart('/').ToLowerInvariant();
        var name = path.Split('/').Last().ToLowerInvariant();
        if (!byName.Value.TryGetValue(name, out var matches)) return null;
        return matches.Where(item => ("/" + item.ToLowerInvariant()).EndsWith(wanted, StringComparison.Ordinal))
            .OrderBy(item => item.Count(ch => ch == '/'))
            .ThenBy(item => item.Length)
            .FirstOrDefault();
    }

    string? Existing(string relative)
    {
        var file = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, relative));
        var real = NoteIndex.Real(System.IO.Path.GetDirectoryName(file)!) + System.IO.Path.DirectorySeparatorChar + System.IO.Path.GetFileName(file);
        var prefix = rootReal.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        if (!real.StartsWith(prefix, StringComparison.Ordinal)) return null;
        if (!File.Exists(real) || Directory.Exists(real)) return null;
        var path = real[prefix.Length..].Replace('\\', '/');
        return path == ".git" || path.StartsWith(".git/", StringComparison.Ordinal) ? null : path;
    }

    Dictionary<string, List<string>> Index()
    {
        var map = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(root)) return map;
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = System.IO.Path.GetRelativePath(root, file).Replace('\\', '/');
            if (relative == ".git" || relative.StartsWith(".git/", StringComparison.Ordinal) || relative.Contains("/.git/", StringComparison.Ordinal))
                continue;
            var name = relative.Split('/').Last();
            if (!map.TryGetValue(name, out var list)) map[name] = list = new List<string>();
            list.Add(relative);
        }
        return map;
    }
}

public static class FileTree
{
    public sealed record Row(NoteEntry Entry, int Depth);

    public static IReadOnlyList<Row> VisibleRows(IReadOnlyList<NoteEntry> tree, IReadOnlySet<string> expanded)
    {
        var rows = new List<Row>();
        void Walk(IReadOnlyList<NoteEntry> entries, int depth)
        {
            foreach (var entry in entries)
            {
                rows.Add(new Row(entry, depth));
                if (entry.IsFolder && expanded.Contains(entry.Path)) Walk(entry.Children, depth + 1);
            }
        }
        Walk(tree, 0);
        return rows;
    }

    public static NoteEntry? Find(IReadOnlyList<NoteEntry> tree, string path)
    {
        foreach (var entry in tree)
        {
            if (entry.Path == path) return entry;
            if (entry.IsFolder && path.StartsWith(entry.Path + "/", StringComparison.Ordinal))
            {
                var found = Find(entry.Children, path);
                if (found != null) return found;
            }
        }
        return null;
    }

    public static string Parent(string path)
    {
        var slash = path.LastIndexOf('/');
        return slash < 0 ? "" : path[..slash];
    }

    public static HashSet<string> Ancestors(string path)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var folder = Parent(path);
        while (folder.Length > 0)
        {
            result.Add(folder);
            folder = Parent(folder);
        }
        return result;
    }

    public static string CurrentFolder(IReadOnlyList<NoteEntry> tree, string highlighted)
    {
        var entry = Find(tree, highlighted);
        if (entry == null) return "";
        return entry.IsFolder ? entry.Path : Parent(entry.Path);
    }

    public static string Moved(string path, string oldPath, string newPath) =>
        path == oldPath || path.StartsWith(oldPath + "/", StringComparison.Ordinal)
            ? newPath + path[oldPath.Length..]
            : path;

    // Whether the source (a file or folder) can be moved into the folder ("" for the root): not where it already is,
    // and a folder not into itself or anything inside it.
    public static bool CanMove(string source, string folder) =>
        folder != Parent(source) && folder != source && !folder.StartsWith(source + "/", StringComparison.Ordinal);

    public static HashSet<string> Renamed(IReadOnlySet<string> expanded, string oldPath, string newPath) =>
        expanded.Select(path => Moved(path, oldPath, newPath)).ToHashSet(StringComparer.Ordinal);

    public static HashSet<string> Removed(IReadOnlySet<string> expanded, string path) =>
        expanded.Where(item => item != path && !item.StartsWith(path + "/", StringComparison.Ordinal)).ToHashSet(StringComparer.Ordinal);
}
