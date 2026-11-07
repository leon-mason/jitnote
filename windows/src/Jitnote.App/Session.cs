using System.Text.Json;

namespace Jitnote;

/// <summary>
/// One running copy of the app: accounts, the open notebook, and the note on screen.
/// Sync still follows the shared rules. This type does not draw the window.
/// </summary>
public sealed class Session
{
    public const string AppVersionLabel = "Jitnote Windows";

    readonly StateStore store;
    readonly HostingApi hosting;
    FolderWatcher? watcher;
    int unsyncedEpoch;

    public Session(string directory, HostingApi? hosting = null, ITokenStore? tokens = null)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
        store = new StateStore(Path.Combine(directory, "state.json"));
        Tokens = tokens ?? TokenStores.Create(directory);
        this.hosting = hosting ?? new HostingApi();
        Device = Environment.MachineName;
        if (Current != null) OpenNotebook(Current);
    }

    public string Directory { get; }
    public AppState State => store.State;
    public ITokenStore Tokens { get; }
    public string Device { get; }

    public Notebook? Current => State.CurrentNotebook;
    public string? OpenPath { get; private set; }
    public string? OpenText { get; private set; }
    public NoteSaver? Saver { get; private set; }
    public bool Syncing { get; private set; }
    long? backgroundAt;
    bool launchHandled;
    public string? Status { get; private set; }
    public bool Unsynced { get; private set; }
    public IReadOnlyList<FileTree.Row> Rows { get; private set; } = Array.Empty<FileTree.Row>();
    public HashSet<string> Expanded { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Side> Choices { get; } = new(StringComparer.Ordinal);

    public event Action? Changed;

    public static string DefaultDirectory()
    {
        var root = OperatingSystem.IsWindows()
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".jitnote-dev");
        return OperatingSystem.IsWindows() ? Path.Combine(root, "Jitnote") : root;
    }

    public string AppVersion()
    {
        var version = typeof(Session).Assembly.GetName().Version;
        return version == null ? "0.0.0" : version.Major + "." + version.Minor + "." + version.Build;
    }

    public Account? AccountOf(Notebook notebook) =>
        State.Accounts.FirstOrDefault(account => account.Id == notebook.AccountId);

    public string FolderOf(Notebook notebook) => notebook.FolderPath ?? "";

    public bool Missing(Notebook notebook) => NotebookFolders.IsMissing(FolderOf(notebook));

    public void Flush()
    {
        SaveOpen();
        SaveState();
    }

    public async Task<Account> Connect(Provider provider, string token, string? username, string? email, CancellationToken cancel = default)
    {
        token = token.Trim();
        if (token.Length == 0) throw new SyncException(SyncErrorKind.Auth, "请粘贴令牌");
        RemoteUser user;
        if (provider == Provider.OTHER)
        {
            var login = (username ?? "").Trim();
            if (login.Length == 0) throw new SyncException(SyncErrorKind.Auth, "请填写用户名");
            var mail = (email ?? "").Trim();
            user = new RemoteUser { Login = login, Email = mail.Length == 0 ? login + "@users.noreply.jitnote" : mail };
        }
        else
        {
            user = await hosting.Verify(provider, token, cancel);
        }
        var existing = State.Accounts.FirstOrDefault(account => account.Provider == provider && account.Login == user.Login);
        var account = new Account
        {
            Id = existing?.Id ?? Guid.NewGuid().ToString(),
            Provider = provider,
            Login = user.Login,
            Email = user.Email,
            CreatedAt = existing?.CreatedAt ?? AppJson.NowMillis(),
        };
        Tokens.Save(account.Id, token);
        State.Accounts.RemoveAll(item => item.Id == account.Id);
        State.Accounts.Add(account);
        SaveState();
        Raise();
        return account;
    }

    public void Disconnect(Account account)
    {
        Tokens.Delete(account.Id);
        State.Accounts.RemoveAll(item => item.Id == account.Id);
        SaveState();
        Raise();
    }

    public async Task<Notebook> CreateNotebook(Account account, string name, string repoPath, string? folder, IProgress<string>? progress, CancellationToken cancel = default)
    {
        var token = Token(account);
        progress?.Report("正在云端创建笔记本…");
        var path = repoPath;
        CreatedRepo? created = null;
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                created = await hosting.CreatePrivateRepo(account.Provider, token, name, path, cancel);
                break;
            }
            catch (NameTakenException)
            {
                if (attempt == 3) throw new SyncException(SyncErrorKind.Other, "这个名称已经被占用");
                path = repoPath + "-" + RepoNames.RandomSuffix();
            }
        }
        var notebook = await Download(name, account, created!.CloneUrl, folder ?? NotebookFolders.DefaultFolder(path), progress, cancel);
        var metaDir = Path.Combine(FolderOf(notebook), ".jitnote");
        System.IO.Directory.CreateDirectory(metaDir);
        var info = new Dictionary<string, object>
        {
            ["schema_version"] = 1,
            ["id"] = notebook.Id,
            ["display_name"] = name,
            ["created_at"] = DateTimeOffset.UtcNow.ToString("o"),
            ["app_version"] = AppVersionLabel + " " + AppVersion(),
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(info, new JsonSerializerOptions { WriteIndented = false });
        await File.WriteAllBytesAsync(Path.Combine(metaDir, "notebook.json"), bytes.Concat(new byte[] { (byte)'\n' }).ToArray(), cancel);
        var author = AuthorOf(account);
        await Task.Run(() => Git(notebook).CommitAll(author, Device, "新建笔记本：" + name), cancel);
        await Sync(notebook);
        return notebook;
    }

    public async Task<IReadOnlyList<(RemoteRepo Repo, bool IsLocal)>> ListRemote(Account account, CancellationToken cancel = default)
    {
        var local = State.Notebooks.Select(notebook => RepoUrls.Key(notebook.RemoteUrl)).ToHashSet();
        var repos = await hosting.ListRepos(account.Provider, Token(account), cancel);
        return repos.Select(repo => (repo, local.Contains(RepoUrls.Key(repo.CloneUrl)))).ToList();
    }

    public async Task<Notebook> ImportNotebook(Account account, string url, string name, string? folder, IProgress<string>? progress, CancellationToken cancel = default)
    {
        var clone = RepoUrls.ToCloneUrl(url.Trim());
        var notebook = await Download(name, account, clone, folder ?? NotebookFolders.DefaultFolder(RepoName(clone)), progress, cancel);
        var meta = Path.Combine(FolderOf(notebook), ".jitnote", "notebook.json");
        if (name.Trim().Length == 0 && File.Exists(meta))
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(meta));
                if (document.RootElement.TryGetProperty("display_name", out var display) && display.GetString() is { Length: > 0 } shown)
                {
                    notebook.Name = shown;
                    SaveState();
                }
            }
            catch { /* a notebook without this file keeps the name from the address */ }
        }
        return notebook;
    }

    public void Select(Notebook notebook)
    {
        SaveOpen();
        State.CurrentNotebookId = notebook.Id;
        SaveState();
        OpenNotebook(notebook);
        Raise();
    }

    public void RemoveLocal(Notebook notebook)
    {
        if (Current?.Id == notebook.Id)
        {
            SaveOpen();
            watcher?.Dispose();
            watcher = null;
            OpenPath = null;
            OpenText = null;
            Saver = null;
        }
        if (!notebook.FolderChosen)
        {
            var folder = FolderOf(notebook);
            if (folder.Length > 0 && System.IO.Directory.Exists(folder))
            {
                try { System.IO.Directory.Delete(folder, true); }
                catch { /* the list still drops the notebook; the folder can be deleted by hand */ }
            }
        }
        State.Notebooks.RemoveAll(item => item.Id == notebook.Id);
        State.ExpandedFolders.Remove(notebook.Id);
        if (State.CurrentNotebookId == notebook.Id) State.CurrentNotebookId = State.Notebooks.FirstOrDefault()?.Id;
        SaveState();
        if (Current != null) OpenNotebook(Current);
        Raise();
    }

    public void Relocate(Notebook notebook, string folder)
    {
        var problem = NotebookFolders.RelocationProblem(folder, Origin(folder), notebook.RemoteUrl, OtherFolders(notebook));
        if (problem != null) throw new SyncException(SyncErrorKind.Other, problem);
        notebook.FolderPath = folder;
        notebook.FolderChosen = !NotebookFolders.IsInDefaultRoot(folder);
        SaveState();
        if (Current?.Id == notebook.Id) OpenNotebook(notebook);
        Raise();
    }

    public async Task Redownload(Notebook notebook, IProgress<string>? progress, CancellationToken cancel = default)
    {
        var account = AccountOf(notebook) ?? throw new SyncException(SyncErrorKind.Auth, "请先连接云端账号");
        var target = FolderOf(notebook);
        var problem = NotebookFolders.RedownloadProblem(target, NotebookFolders.IsInDefaultRoot(target) || target.StartsWith(NotebookFolders.DefaultRoot, StringComparison.Ordinal));
        if (problem != null) throw new SyncException(SyncErrorKind.Other, problem);
        progress?.Report("正在下载笔记本…");
        ClearJunk(target);
        await Task.Run(() => NotebookGit.Clone(notebook.RemoteUrl, target, CredentialsOf(account), null), cancel);
        notebook.LastSyncAt = AppJson.NowMillis();
        notebook.LastSyncError = null;
        SaveState();
        OpenNotebook(notebook);
        Raise();
    }

    public void RefreshTree()
    {
        var notebook = Current;
        if (notebook == null || Missing(notebook))
        {
            Rows = Array.Empty<FileTree.Row>();
            return;
        }
        if (State.ExpandedFolders.TryGetValue(notebook.Id, out var saved))
        {
            foreach (var path in saved) Expanded.Add(path);
        }
        var tree = NoteIndex.Tree(FolderOf(notebook), State.FileSort, State.ShowHiddenFiles);
        Rows = FileTree.VisibleRows(tree, Expanded);
    }

    public void ToggleFolder(string path)
    {
        if (!Expanded.Add(path)) Expanded.Remove(path);
        RememberExpanded();
        RefreshTree();
        Raise();
    }

    public void OpenNote(string path)
    {
        SaveOpen();
        var notebook = Current;
        if (notebook == null) return;
        var full = Path.Combine(FolderOf(notebook), path.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(full) || !NoteIndex.IsEditable(path))
        {
            OpenPath = path;
            OpenText = null;
            Saver = null;
            Raise();
            return;
        }
        var text = File.ReadAllText(full);
        OpenPath = path;
        OpenText = text;
        Saver = new NoteSaver(full, text);
        Raise();
    }

    public void EditorChanged(string markdown)
    {
        if (Syncing || Saver == null) return;
        Saver.MarkEdited();
        if (Saver.Save(markdown)) TouchUnsynced();
    }

    public void SaveOpen()
    {
        if (Syncing || Saver == null || OpenText == null) return;
        if (Saver.Save(OpenText)) TouchUnsynced();
    }

    public void SetOpenText(string text) => OpenText = text;

    public string NewNote(string raw)
    {
        var notebook = NeedNotebook();
        var dir = Path.Combine(FolderOf(notebook), FileTree.CurrentFolder(Tree(), OpenPath ?? "").Replace('/', Path.DirectorySeparatorChar));
        var created = NoteFiles.CreateNote(dir, raw);
        var relative = NoteIndex.Relative(FolderOf(notebook), created);
        foreach (var ancestor in FileTree.Ancestors(relative)) Expanded.Add(ancestor);
        RememberExpanded();
        RefreshTree();
        OpenNote(relative);
        TouchUnsynced();
        return relative;
    }

    public string NewFolder(string raw)
    {
        var notebook = NeedNotebook();
        var dir = Path.Combine(FolderOf(notebook), FileTree.CurrentFolder(Tree(), OpenPath ?? "").Replace('/', Path.DirectorySeparatorChar));
        var created = NoteFiles.CreateFolder(dir, raw);
        var relative = NoteIndex.Relative(FolderOf(notebook), created);
        foreach (var ancestor in FileTree.Ancestors(relative)) Expanded.Add(ancestor);
        Expanded.Add(relative);
        RememberExpanded();
        RefreshTree();
        Raise();
        TouchUnsynced();
        return relative;
    }

    public void RenameItem(string path, string raw)
    {
        var notebook = NeedNotebook();
        var full = Path.Combine(FolderOf(notebook), path.Replace('/', Path.DirectorySeparatorChar));
        var renamed = NoteFiles.Rename(full, raw);
        var relative = NoteIndex.Relative(FolderOf(notebook), renamed);
        var next = new HashSet<string>(FileTree.Renamed(Expanded, path, relative), StringComparer.Ordinal);
        Expanded.Clear();
        foreach (var item in next) Expanded.Add(item);
        RememberExpanded();
        if (OpenPath == path) OpenPath = relative;
        RefreshTree();
        Raise();
        TouchUnsynced();
    }

    public async Task DeleteItem(string path)
    {
        var notebook = NeedNotebook();
        var account = AccountOf(notebook);
        if (account != null)
        {
            var author = AuthorOf(account);
            await Task.Run(() => Git(notebook).CommitPaths(new[] { path }, author, Device));
        }
        var full = Path.Combine(FolderOf(notebook), path.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(full)) File.Delete(full);
        else if (System.IO.Directory.Exists(full)) System.IO.Directory.Delete(full, true);
        if (OpenPath == path)
        {
            OpenPath = null;
            OpenText = null;
            Saver = null;
        }
        RefreshTree();
        Raise();
        TouchUnsynced();
    }

    public void SetHidden(bool show)
    {
        State.ShowHiddenFiles = show;
        SaveState();
        RefreshTree();
        Raise();
    }

    public void SetSort(NoteSort sort)
    {
        State.FileSort = sort;
        SaveState();
        RefreshTree();
        Raise();
    }

    public void SetDefaultView(ViewMode mode)
    {
        State.DefaultViewMode = mode;
        SaveState();
        Raise();
    }

    public void SetSyncOnLaunch(bool enabled)
    {
        State.SyncOnLaunch = enabled;
        SaveState();
        Raise();
    }

    /// <summary>The app is no longer the active one. A later <see cref="OnForeground"/> may auto-sync.</summary>
    public void OnBackground()
    {
        // A deactivate that arrives before the first activate is not "the user left".
        if (launchHandled) backgroundAt = AppJson.NowMillis();
    }

    /// <summary>The app is active again. Does nothing unless「启动时自动同步」is on. See design.md「同步规则」.</summary>
    public void OnForeground()
    {
        var away = backgroundAt is long left ? AppJson.NowMillis() - left : (long?)null;
        backgroundAt = null;
        var handled = launchHandled;
        launchHandled = true;
        var notebook = Current;
        var busy = Syncing || Pending.Count > 0 || (notebook != null && Missing(notebook));
        if (!AutoSync.ShouldStart(State.SyncOnLaunch, busy, notebook != null, away, handled) || notebook == null) return;
        _ = SyncQuiet(notebook);
    }

    async Task SyncQuiet(Notebook notebook)
    {
        try { await Sync(notebook); }
        catch (SyncException) { /* Status already says why. */ }
    }

    public ViewMode ViewFor(string? path)
    {
        if (path != null && !path.EndsWith(".md", StringComparison.OrdinalIgnoreCase)
            && !path.EndsWith(".markdown", StringComparison.OrdinalIgnoreCase))
            return ViewMode.EDIT;
        return State.DefaultViewMode;
    }

    public async Task SyncCurrent()
    {
        if (Current != null) await Sync(Current);
    }

    public async Task Sync(Notebook notebook, IReadOnlyDictionary<string, Side>? extra = null)
    {
        if (extra != null)
        {
            foreach (var pair in extra) Choices[pair.Key] = pair.Value;
        }
        var account = AccountOf(notebook) ?? throw new SyncException(SyncErrorKind.Auth, "请先连接云端账号");
        SaveOpen();
        Syncing = true;
        Status = "正在同步";
        Raise();
        try
        {
            var author = AuthorOf(account);
            var credentials = CredentialsOf(account);
            var choices = Choices.Count == 0 ? null : new Dictionary<string, Side>(Choices);
            var result = await Task.Run(() => Git(notebook).Sync(credentials, author, Device, choices));
            notebook.LastSyncAt = AppJson.NowMillis();
            notebook.LastSyncError = null;
            if (result.Pending.Count > 0)
            {
                Status = "请选择每一篇以哪边为准";
                foreach (var conflict in result.Pending)
                {
                    if (!Choices.ContainsKey(conflict.Path)) { /* asked again */ }
                }
            }
            else
            {
                Choices.Clear();
                Status = null;
            }
            SaveState();
            RefreshTree();
            ReloadOpenFromDisk();
            await RefreshUnsynced();
            if (result.Pending.Count > 0) Pending = result.Pending;
        }
        catch (Exception error)
        {
            var message = error is SyncException sync ? sync.Message : NotebookGit.Classify(error).Message;
            notebook.LastSyncError = message;
            Status = message;
            SaveState();
            throw new SyncException(error is SyncException existing ? existing.Kind : SyncErrorKind.Other, message);
        }
        finally
        {
            Syncing = false;
            Raise();
        }
    }

    public IReadOnlyList<PendingConflict> Pending { get; private set; } = Array.Empty<PendingConflict>();

    public void CancelConflicts()
    {
        Pending = Array.Empty<PendingConflict>();
        Status = null;
        Raise();
    }

    public IReadOnlyList<Version> History(string path) =>
        Current == null ? Array.Empty<Version>() : Git(Current).History(path);

    public string? ReadVersion(string commit, string path)
    {
        if (Current == null) return null;
        var bytes = Git(Current).Read(commit, path);
        return bytes == null ? null : System.Text.Encoding.UTF8.GetString(bytes);
    }

    public void Restore(string path, string commit)
    {
        var notebook = NeedNotebook();
        var account = AccountOf(notebook) ?? throw new SyncException(SyncErrorKind.Auth, "请先连接云端账号");
        Git(notebook).Restore(path, commit, AuthorOf(account), Device);
        ReloadOpenFromDisk();
        RefreshTree();
        TouchUnsynced();
        Raise();
    }

    public async Task<(AppRelease? Release, string? Error)> CheckUpdate(bool manual)
    {
        var version = AppVersion();
        try
        {
            var release = await AppUpdates.Latest(version);
            State.LastUpdateCheckAt = AppJson.NowMillis();
            SaveState();
            if (release == null && manual) return (null, "已是最新版本");
            return (release, null);
        }
        catch
        {
            return (null, manual ? "检查更新没有成功，请检查网络后再试。" : null);
        }
    }

    public bool UpdateDue() => AppUpdates.IsDue(State.LastUpdateCheckAt, AppJson.NowMillis());

    public async Task<string> DownloadUpdate(AppRelease release, IProgress<long>? progress, CancellationToken cancel)
    {
        return await AppUpdates.Download(release, progress, cancel);
    }

    public static void Reveal(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "/select,\"" + path + "\"",
                UseShellExecute = true,
            });
            return;
        }
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "open",
            ArgumentList = { "-R", path },
        });
    }

    public static void OpenFolder(string folder)
    {
        if (OperatingSystem.IsWindows())
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "\"" + folder + "\"",
                UseShellExecute = true,
            });
            return;
        }
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "open",
            ArgumentList = { folder },
        });
    }

    public string? ResolveReference(string reference)
    {
        var notebook = Current;
        if (notebook == null || OpenPath == null) return null;
        var folder = FileTree.Parent(OpenPath);
        var assets = new NoteAssets(FolderOf(notebook));
        var found = assets.Resolve(folder, reference);
        if (found == null) return null;
        var full = Path.Combine(FolderOf(notebook), found.Replace('/', Path.DirectorySeparatorChar));
        return EditorServer.Safe(FolderOf(notebook), found) == null ? null : full;
    }

    async Task<Notebook> Download(string name, Account account, string url, string folder, IProgress<string>? progress, CancellationToken cancel)
    {
        var others = State.Notebooks.Select(FolderOf).ToList();
        var problem = NotebookFolders.Problem(folder, others);
        if (problem != null) throw new SyncException(SyncErrorKind.Other, problem);
        var trimmed = name.Trim();
        var notebook = new Notebook
        {
            Id = Guid.NewGuid().ToString(),
            Name = trimmed.Length == 0 ? RepoName(url) : trimmed,
            AccountId = account.Id,
            RemoteUrl = url,
            Dir = "",
            CreatedAt = AppJson.NowMillis(),
            LastSyncAt = AppJson.NowMillis(),
            FolderPath = folder,
            FolderChosen = !NotebookFolders.IsInDefaultRoot(folder),
        };
        progress?.Report("正在下载笔记本…");
        ClearJunk(folder);
        var credentials = CredentialsOf(account);
        await Task.Run(() => NotebookGit.Clone(url, folder, credentials, (received, total) =>
        {
            if (total > 0) progress?.Report("正在下载笔记本… " + (received * 100 / total) + "%");
        }), cancel);
        State.Notebooks.Add(notebook);
        State.CurrentNotebookId = notebook.Id;
        SaveState();
        OpenNotebook(notebook);
        Raise();
        return notebook;
    }

    void OpenNotebook(Notebook notebook)
    {
        watcher?.Dispose();
        Expanded.Clear();
        if (State.ExpandedFolders.TryGetValue(notebook.Id, out var saved))
        {
            foreach (var path in saved) Expanded.Add(path);
        }
        RefreshTree();
        OpenPath = null;
        OpenText = null;
        Saver = null;
        if (!Missing(notebook))
        {
            watcher = new FolderWatcher(FolderOf(notebook), _ =>
            {
                RefreshTree();
                ReloadOpenFromDisk();
                TouchUnsynced();
                Raise();
            });
        }
        TouchUnsynced();
    }

    void ReloadOpenFromDisk()
    {
        if (Current == null || OpenPath == null || Saver == null) return;
        var full = Path.Combine(FolderOf(Current), OpenPath.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(full)) return;
        var disk = File.ReadAllText(full);
        if (!Saver.ChangedOnDisk(disk)) return;
        Saver.Adopt(disk);
        OpenText = disk;
    }

    IReadOnlyList<NoteEntry> Tree() =>
        Current == null ? Array.Empty<NoteEntry>() : NoteIndex.Tree(FolderOf(Current), State.FileSort, State.ShowHiddenFiles);

    void RememberExpanded()
    {
        if (Current == null) return;
        State.ExpandedFolders[Current.Id] = Expanded.ToHashSet(StringComparer.Ordinal);
        SaveState();
    }

    Notebook NeedNotebook() => Current ?? throw new SyncException(SyncErrorKind.Other, "请先打开一个笔记本");

    NotebookGit Git(Notebook notebook) => new(FolderOf(notebook));

    string Token(Account account) =>
        Tokens.Load(account.Id) ?? throw new SyncException(SyncErrorKind.Auth, "令牌不对或已过期，请重新生成后粘贴");

    Credentials CredentialsOf(Account account) => new(account.Login, Token(account));

    static Author AuthorOf(Account account) => new(account.Login, account.Email);

    List<string> OtherFolders(Notebook notebook) =>
        State.Notebooks.Where(item => item.Id != notebook.Id).Select(FolderOf).ToList();

    static string? Origin(string folder)
    {
        try { return new NotebookGit(folder).OriginUrl(); }
        catch { return null; }
    }

    static void ClearJunk(string folder)
    {
        if (!System.IO.Directory.Exists(folder)) return;
        foreach (var name in new[] { ".DS_Store", "desktop.ini", "Thumbs.db" })
        {
            var file = Path.Combine(folder, name);
            if (File.Exists(file)) File.Delete(file);
        }
    }

    public static string RepoName(string url)
    {
        var name = url.TrimEnd('/');
        var slash = name.LastIndexOf('/');
        if (slash >= 0) name = name[(slash + 1)..];
        if (name.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return name;
    }

    void TouchUnsynced()
    {
        var epoch = ++unsyncedEpoch;
        var notebook = Current;
        if (notebook == null) return;
        _ = Task.Run(() =>
        {
            bool dirty;
            try { dirty = new NotebookGit(FolderOf(notebook)).HasUnsyncedWork(); }
            catch { return; }
            if (epoch != unsyncedEpoch || Current?.Id != notebook.Id) return;
            Unsynced = dirty;
            Raise();
        });
    }

    async Task RefreshUnsynced()
    {
        var notebook = Current;
        if (notebook == null) return;
        try { Unsynced = await Task.Run(() => Git(notebook).HasUnsyncedWork()); }
        catch { /* keep the indicator that was already shown */ }
    }

    void SaveState() => store.Update(_ => { });

    void Raise() => Changed?.Invoke();
}
