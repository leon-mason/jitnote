namespace Jitnote;

/// <summary>
/// Reports files another program creates, changes, renames or deletes, so the tree and the open note follow the disk.
/// Changes inside .git are ignored. Temporary files of an atomic save (the name contains ".sb-") are ignored.
/// An empty path means the watched folder itself is gone.
/// </summary>
public sealed class FolderWatcher : IDisposable
{
    readonly string folder;
    readonly FileSystemWatcher watcher;
    readonly Action<IReadOnlyList<string>> onChange;
    readonly object gate = new();
    readonly HashSet<string> pending = new(StringComparer.Ordinal);
    readonly Timer timer;
    bool stopped;

    public FolderWatcher(string folder, Action<IReadOnlyList<string>> onChange, int latencyMs = 100)
    {
        this.folder = Path.GetFullPath(folder);
        this.onChange = onChange;
        this.latencyMs = latencyMs;
        timer = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
        watcher = new FileSystemWatcher(this.folder)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true,
        };
        watcher.Created += (_, e) => Report(e.FullPath);
        watcher.Changed += (_, e) => Report(e.FullPath);
        watcher.Deleted += (_, e) => Report(e.FullPath);
        watcher.Renamed += (_, e) =>
        {
            Report(e.OldFullPath);
            Report(e.FullPath);
        };
        watcher.Error += (_, _) => Report(this.folder);
    }

    readonly int latencyMs;

    void Report(string? fullPath)
    {
        if (fullPath == null) return;
        string relative;
        if (!Directory.Exists(folder))
        {
            relative = "";
        }
        else
        {
            var full = Path.GetFullPath(fullPath);
            var root = folder.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!full.StartsWith(root, StringComparison.Ordinal) && full != folder.TrimEnd(Path.DirectorySeparatorChar)) return;
            relative = full.Length <= folder.Length ? "" : full[(folder.Length + 1)..].Replace('\\', '/');
        }
        if (relative == ".git" || relative.StartsWith(".git/", StringComparison.Ordinal)) return;
        if (relative.Contains(".sb-", StringComparison.Ordinal)) return;
        lock (gate)
        {
            if (stopped) return;
            pending.Add(relative);
            timer.Change(latencyMs, Timeout.Infinite);
        }
    }

    void Flush()
    {
        string[] batch;
        lock (gate)
        {
            if (pending.Count == 0) return;
            batch = pending.ToArray();
            pending.Clear();
        }
        onChange(batch);
    }

    public void Dispose()
    {
        lock (gate) stopped = true;
        watcher.EnableRaisingEvents = false;
        watcher.Dispose();
        timer.Dispose();
    }
}
