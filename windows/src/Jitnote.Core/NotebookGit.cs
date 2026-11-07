using LibGit2Sharp;
using LibGit2Sharp.Handlers;

namespace Jitnote;

/// <summary>
/// One notebook is one ordinary Git working copy. Sync is commit, fetch, merge, push.
/// Never rebase and never force-push (design.md, 「同步规则」). Conflict detection uses an in-memory
/// merge so the notebook folder is not touched until the user has chosen.
/// </summary>
public sealed class NotebookGit
{
    public const string RemoteName = "origin";
    public const string DefaultBranch = "main";

    // design.md 「同步规则」: a rejected upload retries fetch and merge at most 3 times.
    const int MaxAttempts = 3;

    /// <summary>
    /// How long a sync waits for another program's index.lock. A single command holds it for well under
    /// a second; tests shorten this so they do not sit it out. design.md 「同步规则」.
    /// </summary>
    public static double IndexLockWaitSeconds = 3;

    /// <summary>Written under .git/jitnote while a sync runs. A leftover means a sync of this app died.</summary>
    public const string SyncMarkerPath = "jitnote/syncing";

    public string WorkTree { get; }

    public NotebookGit(string workTree)
    {
        GitNative.Initialize();
        WorkTree = Path.GetFullPath(workTree);
    }

    public string? OriginUrl()
    {
        return WithRepo(repo => repo.Network.Remotes[RemoteName]?.Url);
    }

    public bool HasLocalChanges() => WithRepo(repo => !IsClean(repo));

    /// <summary>True when something on this computer has not reached the cloud yet, including another tool's commits.</summary>
    public bool HasUnsyncedWork()
    {
        return WithRepo(repo =>
        {
            if (!IsClean(repo)) return true;
            var head = HeadCommit(repo);
            if (head == null) return false;
            var remote = RemoteCommit(repo, BranchName(repo));
            if (remote == null) return true;
            return !IsAncestor(repo, head, remote);
        });
    }

    public bool CommitAll(Author author, string device, string? message = null)
    {
        return WithRepo(repo =>
        {
            ApplyIdentity(repo, author);
            return CommitAllInternal(repo, author, device, message);
        });
    }

    public SyncResult Sync(Credentials? credentials, Author author, string device, IReadOnlyDictionary<string, Side>? choices = null)
    {
        try
        {
            return WithRepo(repo => SyncInternal(repo, credentials, author, device, choices ?? new Dictionary<string, Side>()));
        }
        catch (Exception error)
        {
            throw Classify(error);
        }
    }

    public IReadOnlyList<Version> History(string path, int max = 200)
    {
        return WithRepo<IReadOnlyList<Version>>(repo =>
        {
            var head = HeadCommit(repo);
            if (head == null) return Array.Empty<Version>();
            return CommitsTouching(repo, head, path, max).Select(c =>
                new Version(c.Id.Sha, c.Author.When.ToUnixTimeMilliseconds(), c.MessageShort, c.Author.Name)).ToList();
        });
    }

    public byte[]? Read(string commitId, string path)
    {
        return WithRepo(repo =>
        {
            var commit = repo.Lookup<Commit>(commitId);
            return commit == null ? null : BlobBytes(commit, path);
        });
    }

    /// <summary>
    /// Overwrites path with its content at commit. What is there now is recorded first (just this file),
    /// so restoring never loses the current text. The restored text is uploaded on the next sync.
    /// </summary>
    public void Restore(string path, string commitId, Author author, string device)
    {
        WithRepo(repo =>
        {
            var commit = repo.Lookup<Commit>(commitId) ?? throw new SyncException(SyncErrorKind.Other, "找不到这个历史版本");
            var content = BlobBytes(commit, path);
            ApplyIdentity(repo, author);
            CommitPathsInternal(repo, new[] { path }, author, device, null);
            WriteOrDelete(path, content);
            return 0;
        });
    }

    /// <summary>
    /// Commits only these paths. Every other change stays uncommitted, including whatever another tool staged.
    /// Paths are literal: a note named a[1].md is not a glob. Used before the app deletes or overwrites a file.
    /// </summary>
    public bool CommitPaths(IReadOnlyList<string> paths, Author author, string device, string? message = null)
    {
        return WithRepo(repo =>
        {
            ApplyIdentity(repo, author);
            return CommitPathsInternal(repo, paths, author, device, message);
        });
    }

    public static NotebookGit Clone(string url, string directory, Credentials? credentials, Action<int, int>? onProgress = null)
    {
        GitNative.Initialize();
        var dir = Path.GetFullPath(directory);
        var existed = Directory.Exists(dir);
        try
        {
            var fetch = new FetchOptions { Prune = true, CredentialsProvider = CredentialHandler(credentials) };
            if (onProgress != null)
            {
                fetch.OnTransferProgress = progress =>
                {
                    onProgress(progress.ReceivedObjects, Math.Max(progress.TotalObjects, 1));
                    return true;
                };
            }
            Repository.Clone(url, dir, new CloneOptions(fetch));
            Prepare(dir);
        }
        catch (Exception error)
        {
            // A folder the user chose must survive a failed download. Only what the download put there is removed.
            if (existed)
            {
                if (Directory.Exists(dir))
                {
                    foreach (var item in Directory.GetFileSystemEntries(dir))
                    {
                        if (Directory.Exists(item)) Directory.Delete(item, true);
                        else File.Delete(item);
                    }
                }
            }
            else if (Directory.Exists(dir))
            {
                Directory.Delete(dir, true);
            }
            throw Classify(error);
        }
        return new NotebookGit(dir);
    }

    SyncResult SyncInternal(Repository repo, Credentials? credentials, Author author, string device, IReadOnlyDictionary<string, Side> choices)
    {
        PrepareForSync(repo);
        try
        {
            ApplyIdentity(repo, author);
            var legacy = Path.Combine(GitDir, "jitnote", "conflicts.json");
            if (File.Exists(legacy)) File.Delete(legacy);
            CommitAllInternal(repo, author, device, null);
            var branch = BranchName(repo);
            var pulled = false;
            var resolved = 0;
            for (var attempt = 0; attempt < MaxAttempts; attempt++)
            {
                Fetch(repo, credentials);
                var remote = RemoteCommit(repo, branch);
                if (remote != null)
                {
                    var merge = MergeRemote(repo, remote, branch, author, device, choices);
                    if (merge.Pending.Count > 0)
                        return new SyncResult(pulled, false, resolved, merge.Pending);
                    pulled = pulled || merge.Changed;
                    resolved += merge.Resolved;
                }
                var local = HeadCommit(repo);
                if (local == null || remote != null && local.Id == remote.Id)
                    return new SyncResult(pulled, false, resolved, Array.Empty<PendingConflict>());
                if (Push(repo, branch, credentials))
                {
                    EnsureUpstream(repo, branch);
                    return new SyncResult(pulled, true, resolved, Array.Empty<PendingConflict>());
                }
            }
            throw new SyncException(SyncErrorKind.Rejected, "云端在同步期间不断变化，请稍后再试");
        }
        finally
        {
            ReleaseSyncMarker(repo);
        }
    }

    void Fetch(Repository repo, Credentials? credentials)
    {
        var remote = repo.Network.Remotes[RemoteName] ?? throw new SyncException(SyncErrorKind.Other, "这个笔记本没有云端地址");
        var specs = remote.FetchRefSpecs.Select(spec => spec.Specification).ToList();
        if (specs.Count == 0) specs.Add($"+refs/heads/*:refs/remotes/{RemoteName}/*");
        var options = new FetchOptions { Prune = true, CredentialsProvider = CredentialHandler(credentials) };
        Commands.Fetch(repo, remote.Name, specs, options, "fetch");
    }

    sealed record MergeOutcome(bool Changed, int Resolved, IReadOnlyList<PendingConflict> Pending);

    MergeOutcome MergeRemote(Repository repo, Commit theirs, string branch, Author author, string device, IReadOnlyDictionary<string, Side> choices)
    {
        var head = HeadCommit(repo);
        if (head == null)
        {
            Adopt(repo, theirs, branch);
            return new MergeOutcome(true, 0, Array.Empty<PendingConflict>());
        }
        if (IsAncestor(repo, theirs, head)) return new MergeOutcome(false, 0, Array.Empty<PendingConflict>());
        if (IsAncestor(repo, head, theirs))
        {
            FastForward(repo, theirs);
            return new MergeOutcome(true, 0, Array.Empty<PendingConflict>());
        }

        // In memory only. Repository.Merge would write conflict markers into the notebook, where another program could read them.
        var conflicts = FindConflicts(repo, head, theirs);
        if (conflicts.Any(conflict => !choices.ContainsKey(conflict.Path)))
            return new MergeOutcome(false, 0, conflicts);

        MergeResult merged;
        try
        {
            merged = repo.Merge(theirs, SignatureOf(author), new MergeOptions
            {
                FastForwardStrategy = FastForwardStrategy.NoFastForward,
                CommitOnSuccess = false,
                FailOnConflict = false,
            });
        }
        catch (CheckoutConflictException)
        {
            throw new SyncException(SyncErrorKind.Other, "有文件正在被修改，请稍后再同步");
        }
        if (merged.Status == MergeStatus.Conflicts)
        {
            var count = ResolveConflicts(repo, head, theirs, author, device, choices);
            return new MergeOutcome(true, count, Array.Empty<PendingConflict>());
        }
        CommitHead(repo, author, CommitMessage("同步：合并云端修改", device));
        return new MergeOutcome(true, 0, Array.Empty<PendingConflict>());
    }

    static List<PendingConflict> FindConflicts(Repository repo, Commit ours, Commit theirs)
    {
        var result = repo.ObjectDatabase.MergeCommits(ours, theirs, new MergeTreeOptions());
        if (result.Status != MergeTreeStatus.Conflicts || result.Conflicts == null) return new List<PendingConflict>();
        var found = new List<PendingConflict>();
        foreach (var conflict in result.Conflicts)
        {
            var oursEntry = conflict.Ours;
            var theirsEntry = conflict.Theirs;
            if (oursEntry == null && theirsEntry == null) continue;
            var path = oursEntry?.Path ?? theirsEntry?.Path ?? conflict.Ancestor?.Path;
            if (path == null) continue;
            found.Add(new PendingConflict(path, Bytes(repo, oursEntry), Bytes(repo, theirsEntry)));
        }
        return found;
    }

    int ResolveConflicts(Repository repo, Commit ours, Commit theirs, Author author, string device, IReadOnlyDictionary<string, Side> choices)
    {
        var stages = repo.Index.Conflicts.ToList();
        foreach (var stage in stages)
        {
            var path = stage.Ours?.Path ?? stage.Theirs?.Path ?? stage.Ancestor?.Path;
            if (path == null) continue;
            if (!choices.TryGetValue(path, out var side))
                throw new SyncException(SyncErrorKind.Other, "合并时发现新的冲突，请重新同步");
            var chosen = side == Side.LOCAL ? stage.Ours : stage.Theirs;
            if (chosen != null)
            {
                WriteOrDelete(path, Bytes(repo, chosen));
                repo.Index.Add(path);
            }
            else
            {
                WriteOrDelete(path, null);
                repo.Index.Remove(path);
            }
        }
        repo.Index.Write();
        CommitHead(repo, author, CommitMessage($"同步：合并云端修改（{stages.Count} 个文件两边都改了，按你的选择处理）", device));
        return stages.Count;
    }

    bool Push(Repository repo, string branch, Credentials? credentials)
    {
        string? rejection = null;
        var options = new PushOptions
        {
            CredentialsProvider = CredentialHandler(credentials),
            OnPushStatusError = error => rejection = error.Message,
        };
        try
        {
            repo.Network.Push(repo.Network.Remotes[RemoteName], $"refs/heads/{branch}:refs/heads/{branch}", options);
        }
        catch (NonFastForwardException)
        {
            return false;
        }
        catch (LibGit2SharpException error) when (IsNonFastForward(error.Message))
        {
            return false;
        }
        if (rejection == null) return true;
        if (IsNonFastForward(rejection)) return false;
        throw new SyncException(SyncErrorKind.Rejected, "云端拒绝了上传：" + rejection);
    }

    static bool IsNonFastForward(string message)
    {
        var lower = message.ToLowerInvariant();
        return lower.Contains("non-fast-forward") || lower.Contains("fetch first") || lower.Contains("stale");
    }

    void PrepareForSync(Repository repo)
    {
        var marker = SyncMarkerFile;
        if (File.Exists(marker))
        {
            Recover(repo);
        }
        else
        {
            var deadline = DateTime.UtcNow.AddSeconds(IndexLockWaitSeconds);
            while (File.Exists(IndexLock))
            {
                if (DateTime.UtcNow >= deadline)
                    throw new SyncException(SyncErrorKind.Other, "有其他程序正在处理这个笔记本，请稍后再同步");
                Thread.Sleep(100);
            }
            // No marker: an unfinished merge belongs to another program. Do not clean it up.
            if (repo.Info.CurrentOperation != CurrentOperation.None)
                throw new SyncException(SyncErrorKind.Other, "有其他程序正在合并这个笔记本，请等它完成后再同步");
        }
        Directory.CreateDirectory(Path.GetDirectoryName(marker)!);
        File.WriteAllBytes(marker, Array.Empty<byte>());
    }

    void ReleaseSyncMarker(Repository repo)
    {
        if (repo.Info.CurrentOperation != CurrentOperation.None) return;
        if (File.Exists(SyncMarkerFile)) File.Delete(SyncMarkerFile);
    }

    void Recover(Repository repo)
    {
        // Only this app's crashed sync may remove the lock. Local work was committed before the merge.
        if (File.Exists(IndexLock)) File.Delete(IndexLock);
        if (repo.Info.CurrentOperation == CurrentOperation.None) return;
        var head = HeadCommit(repo);
        if (head != null) repo.Reset(ResetMode.Hard, head);
    }

    bool CommitAllInternal(Repository repo, Author author, string device, string? message)
    {
        if (IsClean(repo)) return false;
        StageWorkdir(repo);
        var head = HeadCommit(repo);
        var (added, changed, removed) = Changes(repo, head?.Tree, null);
        var summary = message ?? DescribeChanges(added, changed, removed);
        if (summary == null) return false;
        CommitHead(repo, author, CommitMessage(summary, device));
        return true;
    }

    bool CommitPathsInternal(Repository repo, IReadOnlyList<string> paths, Author author, string device, string? message)
    {
        foreach (var path in paths) Stage(repo, path);
        repo.Index.Write();
        var head = HeadCommit(repo);
        var (added, changed, removed) = Changes(repo, head?.Tree, paths);
        var summary = message ?? DescribeChanges(added, changed, removed);
        if (summary == null) return false;

        // The version is HEAD's tree plus just these paths. Committing the real index would also
        // record whatever else is staged there.
        var definition = head == null ? new TreeDefinition() : TreeDefinition.From(head.Tree);
        foreach (var path in removed) definition.Remove(path);
        foreach (var path in added.Concat(changed))
        {
            var entry = repo.Index[path];
            if (entry == null) continue;
            definition.Add(path, entry.Id, entry.Mode);
        }
        var tree = repo.ObjectDatabase.CreateTree(definition);
        var parents = head == null ? Array.Empty<Commit>() : new[] { head };
        var commit = repo.ObjectDatabase.CreateCommit(SignatureOf(author), SignatureOf(author), CommitMessage(summary, device), tree, parents, false);
        MoveHead(repo, commit);
        return true;
    }

    void Stage(Repository repo, string path)
    {
        var full = Path.Combine(WorkTree, path.Replace('/', Path.DirectorySeparatorChar));
        var onDisk = new HashSet<string>(StringComparer.Ordinal);
        if (Directory.Exists(full))
        {
            foreach (var file in Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories))
            {
                var relative = Path.GetRelativePath(WorkTree, file).Replace('\\', '/');
                onDisk.Add(relative);
            }
        }
        else if (File.Exists(full))
        {
            onDisk.Add(path.Replace('\\', '/'));
        }
        foreach (var file in onDisk)
        {
            // New files obey .gitignore. A file that is already tracked is recorded either way.
            if (repo.Index[file] == null && repo.Ignore.IsPathIgnored(file)) continue;
            repo.Index.Add(file);
        }
        foreach (var entry in repo.Index.ToList())
        {
            var tracked = entry.Path.Replace('\\', '/');
            if ((tracked == path || tracked.StartsWith(path + "/", StringComparison.Ordinal)) && !onDisk.Contains(tracked))
                repo.Index.Remove(tracked);
        }
    }

    static void StageWorkdir(Repository repo)
    {
        var options = new StatusOptions
        {
            IncludeUntracked = true,
            RecurseUntrackedDirs = true,
            ExcludeSubmodules = true,
            DetectRenamesInIndex = false,
            DetectRenamesInWorkDir = false,
        };
        foreach (var item in repo.RetrieveStatus(options))
        {
            var state = item.State;
            if (state.HasFlag(FileStatus.Ignored) || state.HasFlag(FileStatus.Unreadable)) continue;
            var deleted = state.HasFlag(FileStatus.DeletedFromWorkdir) || state.HasFlag(FileStatus.DeletedFromIndex);
            var interesting = deleted
                || state.HasFlag(FileStatus.NewInWorkdir)
                || state.HasFlag(FileStatus.ModifiedInWorkdir)
                || state.HasFlag(FileStatus.TypeChangeInWorkdir)
                || state.HasFlag(FileStatus.RenamedInWorkdir)
                || state.HasFlag(FileStatus.NewInIndex)
                || state.HasFlag(FileStatus.ModifiedInIndex)
                || state.HasFlag(FileStatus.RenamedInIndex)
                || state.HasFlag(FileStatus.TypeChangeInIndex)
                || state.HasFlag(FileStatus.Conflicted);
            if (!interesting) continue;
            if (deleted)
            {
                if (repo.Index[item.FilePath] != null) repo.Index.Remove(item.FilePath);
            }
            else
            {
                repo.Index.Add(item.FilePath);
            }
        }
        repo.Index.Write();
    }

    (List<string> Added, List<string> Changed, List<string> Removed) Changes(Repository repo, Tree? headTree, IReadOnlyList<string>? only)
    {
        var added = new List<string>();
        var changed = new List<string>();
        var removed = new List<string>();
        if (headTree == null)
        {
            foreach (var entry in repo.Index)
            {
                if (only != null && !Under(entry.Path, only)) continue;
                added.Add(entry.Path);
            }
            return (added, changed, removed);
        }
        var diff = repo.Diff.Compare<TreeChanges>(headTree, DiffTargets.Index);
        foreach (var change in diff)
        {
            var path = change.Status == ChangeKind.Deleted ? change.OldPath : change.Path;
            if (only != null && !Under(path, only)) continue;
            switch (change.Status)
            {
                case ChangeKind.Added:
                    added.Add(path);
                    break;
                case ChangeKind.Deleted:
                    removed.Add(path);
                    break;
                case ChangeKind.Renamed:
                    removed.Add(change.OldPath);
                    added.Add(change.Path);
                    break;
                default:
                    changed.Add(path);
                    break;
            }
        }
        return (added, changed, removed);
    }

    static bool Under(string path, IReadOnlyList<string> roots) =>
        roots.Any(root => path == root || path.StartsWith(root + "/", StringComparison.Ordinal));

    static bool IsClean(Repository repo)
    {
        var options = new StatusOptions
        {
            IncludeUntracked = true,
            RecurseUntrackedDirs = true,
            ExcludeSubmodules = true,
        };
        return !repo.RetrieveStatus(options).IsDirty;
    }

    static Commit? HeadCommit(Repository repo) => repo.Info.IsHeadUnborn ? null : repo.Head.Tip;

    static Commit? RemoteCommit(Repository repo, string branch)
    {
        var reference = repo.Refs[$"refs/remotes/{RemoteName}/{branch}"];
        var id = (reference as DirectReference)?.Target.Id;
        return id == null ? null : repo.Lookup<Commit>(id);
    }

    static string BranchName(Repository repo)
    {
        if (repo.Refs["HEAD"] is SymbolicReference head && head.TargetIdentifier.StartsWith("refs/heads/", StringComparison.Ordinal))
            return head.TargetIdentifier["refs/heads/".Length..];
        throw new SyncException(SyncErrorKind.Other, "笔记本没有处在任何分支上");
    }

    static bool IsAncestor(Repository repo, Commit ancestor, Commit descendant)
    {
        if (ancestor.Id == descendant.Id) return true;
        var seen = new HashSet<ObjectId>();
        var stack = new Stack<Commit>();
        stack.Push(descendant);
        while (stack.Count > 0)
        {
            var commit = stack.Pop();
            if (!seen.Add(commit.Id)) continue;
            if (commit.Id == ancestor.Id) return true;
            foreach (var parent in commit.Parents) stack.Push(parent);
        }
        return false;
    }

    static byte[]? BlobBytes(Commit commit, string path)
    {
        var entry = commit[path];
        if (entry == null || entry.TargetType != TreeEntryTargetType.Blob) return null;
        return ReadBlob((Blob)entry.Target);
    }

    static byte[]? Bytes(Repository repo, IndexEntry? entry)
    {
        if (entry == null) return null;
        var blob = repo.Lookup<Blob>(entry.Id);
        return blob == null ? null : ReadBlob(blob);
    }

    static byte[] ReadBlob(Blob blob)
    {
        using var stream = blob.GetContentStream();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    static List<Commit> CommitsTouching(Repository repo, Commit from, string path, int max)
    {
        var filter = new CommitFilter
        {
            SortBy = CommitSortStrategies.Topological | CommitSortStrategies.Time,
            IncludeReachableFrom = from,
        };
        var result = new List<Commit>();
        foreach (var commit in repo.Commits.QueryBy(filter))
        {
            if (result.Count >= max) break;
            if (Touches(commit, path)) result.Add(commit);
        }
        return result;
    }

    static bool Touches(Commit commit, string path)
    {
        var mine = BlobId(commit, path);
        if (!commit.Parents.Any()) return mine != null;
        foreach (var parent in commit.Parents)
        {
            if (BlobId(parent, path) == mine) return false;
        }
        return true;
    }

    static ObjectId? BlobId(Commit commit, string path)
    {
        var entry = commit[path];
        return entry != null && entry.TargetType == TreeEntryTargetType.Blob ? entry.Target.Id : null;
    }

    void CommitHead(Repository repo, Author author, string message)
    {
        repo.Commit(message, SignatureOf(author), SignatureOf(author), new CommitOptions { PrettifyMessage = false });
    }

    static void FastForward(Repository repo, Commit target)
    {
        try
        {
            repo.Merge(target, SignatureOf(new Author("记特", "jitnote@localhost")), new MergeOptions
            {
                FastForwardStrategy = FastForwardStrategy.FastForwardOnly,
                CommitOnSuccess = false,
            });
        }
        catch (CheckoutConflictException)
        {
            throw new SyncException(SyncErrorKind.Other, "有文件正在被修改，请稍后再同步");
        }
    }

    static void Adopt(Repository repo, Commit theirs, string branch)
    {
        var name = "refs/heads/" + branch;
        var existing = repo.Refs[name];
        if (existing == null) repo.Refs.Add(name, theirs.Id);
        else repo.Refs.UpdateTarget(existing, theirs.Id);
        Commands.Checkout(repo, theirs, new CheckoutOptions { CheckoutModifiers = CheckoutModifiers.Force });
        // Checkout of a commit leaves HEAD detached. Point it back at the branch, or the next upload sends nothing.
        if (repo.Info.IsHeadDetached)
            repo.Refs.UpdateTarget("HEAD", name);
    }

    static void ApplyIdentity(Repository repo, Author author)
    {
        // Give other tools a name, but never replace one the user already chose. This app's own versions name their author explicitly.
        if (ConfigString(repo, "user.name") == null)
            repo.Config.Set("user.name", author.Name, ConfigurationLevel.Local);
        if (ConfigString(repo, "user.email") == null)
            repo.Config.Set("user.email", author.Email, ConfigurationLevel.Local);
    }

    static void EnsureUpstream(Repository repo, string branch)
    {
        if (ConfigString(repo, "branch." + branch + ".remote") != null) return;
        repo.Config.Set("branch." + branch + ".remote", RemoteName, ConfigurationLevel.Local);
        repo.Config.Set("branch." + branch + ".merge", "refs/heads/" + branch, ConfigurationLevel.Local);
    }

    static string? ConfigString(Repository repo, string key)
    {
        var entry = repo.Config.Get<string>(key);
        return string.IsNullOrEmpty(entry?.Value) ? null : entry.Value;
    }

    void WriteOrDelete(string path, byte[]? content)
    {
        var file = Path.Combine(WorkTree, path.Replace('/', Path.DirectorySeparatorChar));
        if (content != null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllBytes(file, content);
        }
        else if (File.Exists(file))
        {
            File.Delete(file);
        }
    }

    static void MoveHead(Repository repo, Commit commit)
    {
        // Move the branch HEAD points at. Updating the symbolic HEAD itself would detach it,
        // and the upload would then send the old branch.
        var name = "refs/heads/" + (repo.Info.IsHeadUnborn ? BranchName(repo) : BranchName(repo));
        var reference = repo.Refs[name];
        if (reference == null) repo.Refs.Add(name, commit.Id);
        else repo.Refs.UpdateTarget(reference, commit.Id);
    }

    static void Prepare(string dir)
    {
        using var repo = new Repository(dir);
        // Store file names composed (NFC), as Git on other systems expects.
        repo.Config.Set("core.precomposeunicode", true, ConfigurationLevel.Local);
        if (!repo.Info.IsHeadUnborn) return;
        var any = repo.Refs.Any(reference => reference.CanonicalName != "HEAD");
        if (any) return;
        // A name, not a commit: the branch does not exist until the first version is recorded.
        repo.Refs.UpdateTarget("HEAD", "refs/heads/" + DefaultBranch);
    }

    static Signature SignatureOf(Author author) => new(author.Name, author.Email, DateTimeOffset.Now);

    static CredentialsHandler CredentialHandler(Credentials? credentials) => (_, _, _) =>
        credentials == null
            ? new DefaultCredentials()
            : new UsernamePasswordCredentials { Username = credentials.Username, Password = credentials.Password };

    string GitDir => Path.Combine(WorkTree, ".git");
    string SyncMarkerFile => Path.Combine(GitDir, SyncMarkerPath.Replace('/', Path.DirectorySeparatorChar));
    string IndexLock => Path.Combine(GitDir, "index.lock");

    T WithRepo<T>(Func<Repository, T> body)
    {
        using var repo = new Repository(WorkTree);
        return body(repo);
    }

    public static string CommitMessage(string summary, string device) => summary + "\n\n来自 记特 · " + device;

    public static string? DescribeChanges(IReadOnlyList<string> added, IReadOnlyList<string> changed, IReadOnlyList<string> removed)
    {
        var total = added.Count + changed.Count + removed.Count;
        if (total == 0) return null;
        if (changed.Count == 0 && DescribeMove(added, removed) is { } move) return move;
        if (total == 1)
        {
            if (added.Count == 1) return "新建：" + Title(added[0]);
            if (changed.Count == 1) return "编辑：" + Title(changed[0]);
            return "删除：" + Title(removed[0]);
        }
        var names = new List<string>();
        foreach (var name in changed.Concat(added).Concat(removed).Select(Title))
        {
            if (!names.Contains(name)) names.Add(name);
        }
        var more = names.Count > 3 ? " 等" : "";
        return "更新 " + total + " 个文件：" + string.Join("、", names.Take(3)) + more;
    }

    // "移动：…" or "重命名：…" when the only change is files that disappeared and reappeared elsewhere
    // (design.md「同步规则」). Without this a file moved to another folder would read as
    // "重命名：读书笔记 → 读书笔记". A folder that moved as a whole is recognised by its files keeping
    // their paths relative to it; anything else falls back to the generic summary.
    static string? DescribeMove(IReadOnlyList<string> added, IReadOnlyList<string> removed)
    {
        if (added.Count == 1 && removed.Count == 1)
        {
            var from = removed[0];
            var to = added[0];
            var fromDir = DirectoryOf(from);
            var toDir = DirectoryOf(to);
            if (fromDir == toDir) return "重命名：" + Title(from) + " → " + Title(to);
            if (from.Split('/').Last() == to.Split('/').Last()) return "移动：" + Title(from) + " → " + FolderLabel(toDir);
            return "重命名：" + Title(from) + " → " + (toDir.Length == 0 ? "" : toDir + "/") + Title(to);
        }
        if (added.Count != removed.Count || added.Count == 0) return null;
        var oldDir = CommonDirectory(removed);
        var newDir = CommonDirectory(added);
        var same = 0;
        while (same < oldDir.Length && same < newDir.Length && oldDir[^(same + 1)] == newDir[^(same + 1)]) same++;
        if (same == 0) return null;
        static HashSet<string> Inside(IReadOnlyList<string> paths, string[] dir) =>
            paths.Select(path => string.Join("/", path.Split('/').Skip(dir.Length))).ToHashSet(StringComparer.Ordinal);
        if (!Inside(removed, oldDir).SetEquals(Inside(added, newDir))) return null;
        return "移动：" + oldDir[oldDir.Length - same] + " → " + FolderLabel(string.Join("/", newDir.Take(newDir.Length - same)));
    }

    static string DirectoryOf(string path) => string.Join("/", path.Split('/').SkipLast(1));

    static string FolderLabel(string dir) => dir.Length == 0 ? "根目录" : dir;

    // The deepest folder that contains every path (empty for the notebook root), as path components.
    static string[] CommonDirectory(IReadOnlyList<string> paths)
    {
        var common = paths[0].Split('/').SkipLast(1).ToArray();
        foreach (var path in paths)
        {
            var dir = path.Split('/').SkipLast(1).ToArray();
            var n = 0;
            while (n < common.Length && n < dir.Length && common[n] == dir[n]) n++;
            common = common.Take(n).ToArray();
        }
        return common;
    }

    public static string Title(string path)
    {
        var name = path.Split('/').Last();
        foreach (var ext in new[] { ".md", ".markdown" })
        {
            if (name.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) return name[..^ext.Length];
        }
        return name;
    }

    // libgit2 error numbers. Classified before the network words: a certificate failure mentions SSL, and retrying will not help.
    const int GitEConflict = -13;
    const int GitEAuth = -16;
    const int GitECertificate = -17;

    public static SyncException Classify(Exception error, int? gitCode = null)
    {
        if (error is SyncException sync) return sync;
        var message = error.Message;
        var text = message.ToLowerInvariant();
        if (gitCode == GitEAuth || ContainsAny(text, "authentication", "401", "403", "not authorized", "not permitted", "credentials"))
            return new SyncException(SyncErrorKind.Auth, "账号授权无效或已过期，请到「云端账号」里重新连接");
        if (gitCode == GitECertificate)
            return new SyncException(SyncErrorKind.Network, "无法验证云端的安全证书，请检查电脑时间和代理设置后重试（" + message + "）");
        if (ContainsAny(text, "failed to resolve address", "could not resolve", "failed to connect", "connection refused", "timed out", "network is unreachable", "socket", "ssl", "tls", "connection reset"))
            return new SyncException(SyncErrorKind.Network, "网络连接失败，请检查网络后重试");
        if (ContainsAny(text, "not found", "404", "does not appear to be a git repository"))
            return new SyncException(SyncErrorKind.NotFound, "找不到云端的笔记本，可能已被删除，或这个账号没有权限");
        if (gitCode == GitEConflict)
            return new SyncException(SyncErrorKind.Other, "有文件正在被修改，请稍后再同步");
        return new SyncException(SyncErrorKind.Other, message);
    }

    static bool ContainsAny(string text, params string[] needles) => needles.Any(text.Contains);

    internal static string? ReadConfig(string workTree, string key)
    {
        GitNative.Initialize();
        using var repo = new Repository(workTree);
        return ConfigString(repo, key);
    }

    internal static void WriteConfig(string workTree, string key, string value)
    {
        GitNative.Initialize();
        using var repo = new Repository(workTree);
        repo.Config.Set(key, value, ConfigurationLevel.Local);
    }

    internal static string RepositoryState(string workTree)
    {
        GitNative.Initialize();
        using var repo = new Repository(workTree);
        return repo.Info.CurrentOperation == CurrentOperation.None ? "none"
            : repo.Info.CurrentOperation == CurrentOperation.Merge ? "merge"
            : repo.Info.CurrentOperation.ToString().ToLowerInvariant();
    }

    internal static IReadOnlyList<string> Log(string workTree)
    {
        GitNative.Initialize();
        using var repo = new Repository(workTree);
        if (repo.Info.IsHeadUnborn) return Array.Empty<string>();
        var filter = new CommitFilter
        {
            SortBy = CommitSortStrategies.Topological | CommitSortStrategies.Time,
            IncludeReachableFrom = repo.Head.Tip,
        };
        return repo.Commits.QueryBy(filter).Select(commit => commit.MessageShort).ToList();
    }

    internal static void InitBareMain(string path)
    {
        GitNative.Initialize();
        Directory.CreateDirectory(path);
        Repository.Init(path, true);
        // A bare init often starts on master, and that branch has no commit yet, so rewrite the HEAD file.
        File.WriteAllText(Path.Combine(path, "HEAD"), "ref: refs/heads/" + DefaultBranch + "\n");
    }
}
