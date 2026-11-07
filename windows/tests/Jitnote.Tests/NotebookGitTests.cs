using LibGit2Sharp;
using Xunit;

namespace Jitnote.Tests;

public class NotebookGitTests : IDisposable
{
    static readonly Author Author = new("Tester", "tester@example.com");
    readonly string root = Path.Combine(Path.GetTempPath(), "jitnote-tests", Guid.NewGuid().ToString("n"));

    public NotebookGitTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);

    sealed class Cloud
    {
        public Cloud(string root)
        {
            Root = root;
            NotebookGit.InitBareMain(Path.Combine(root, "cloud.git"));
        }

        public string Root { get; }
        public string Url => Path.Combine(Root, "cloud.git");
        public NotebookGit Device(string name) => NotebookGit.Clone(Url, Path.Combine(Root, name), null);
    }

    static void Write(NotebookGit git, string path, string text)
    {
        var file = Path.Combine(git.WorkTree, path.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, text);
    }

    static string Read(NotebookGit git, string path) =>
        File.ReadAllText(Path.Combine(git.WorkTree, path.Replace('/', Path.DirectorySeparatorChar)));

    static SyncResult Sync(NotebookGit git, string name = "phone", Dictionary<string, Side>? choices = null) =>
        git.Sync(null, Author, name, choices);

    static bool HistoryHas(NotebookGit git, string path, string text) =>
        git.History(path).Any(version => git.Read(version.Commit, path) is { } bytes && System.Text.Encoding.UTF8.GetString(bytes) == text);

    static (NotebookGit A, NotebookGit B) Diverged(Cloud cloud)
    {
        var a = cloud.Device("a");
        Write(a, "note.md", "base");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "note.md", "from a");
        Sync(a);
        Write(b, "note.md", "from b");
        b.CommitAll(Author, "b");
        return (a, b);
    }

    static string CloudHead(Cloud cloud) => cloud.Device("probe-" + Guid.NewGuid().ToString("n")).History("note.md")[0].Commit;

    static NotebookGit StartConflictingMerge(Cloud cloud)
    {
        var a = cloud.Device("a");
        Write(a, "note.md", "base");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "note.md", "a");
        Sync(a);
        Write(b, "note.md", "b");
        b.CommitAll(Author, "b");
        using var repo = new Repository(b.WorkTree);
        Commands.Fetch(repo, "origin", new[] { "+refs/heads/*:refs/remotes/origin/*" }, new FetchOptions(), "fetch");
        var theirs = repo.Lookup<Commit>((repo.Refs["refs/remotes/origin/main"] as DirectReference)!.Target.Id);
        repo.Merge(theirs, new Signature("Tester", "tester@example.com", DateTimeOffset.Now), new MergeOptions
        {
            FastForwardStrategy = FastForwardStrategy.NoFastForward,
            CommitOnSuccess = false,
            FailOnConflict = false,
        });
        Assert.Equal("merge", NotebookGit.RepositoryState(b.WorkTree));
        return b;
    }

    [Fact]
    public void FirstSyncOfEmptyCloudRepositoryPushesToMain()
    {
        var cloud = new Cloud(root);
        var phone = cloud.Device("phone");
        Write(phone, "第一篇.md", "# 你好");
        var result = Sync(phone);
        Assert.True(result.Pushed);
        Assert.Equal("# 你好", Read(cloud.Device("laptop"), "第一篇.md"));
        Assert.Equal(new[] { "新建：第一篇" }, NotebookGit.Log(phone.WorkTree));
    }

    [Fact]
    public void SyncRecordsEveryChangeAsOneVersionAndNothingBeforeThat()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "a.md", "1");
        Write(a, "b.md", "2");
        Write(a, "dir/c.md", "3");
        Assert.True(a.HasUnsyncedWork());
        Sync(a);
        Assert.Equal(new[] { "更新 3 个文件：a、b、c" }, NotebookGit.Log(a.WorkTree));
        Assert.False(a.HasUnsyncedWork());
    }

    [Fact]
    public void PullsCloudChangesByFastForward()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "note.md", "v1");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "note.md", "v2");
        Sync(a);
        var result = Sync(b);
        Assert.True(result.Pulled);
        Assert.False(result.Pushed);
        Assert.Equal("v2", Read(b, "note.md"));
        Assert.Empty(result.Pending);
    }

    [Fact]
    public void MergesEditsToDifferentFiles()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "a.md", "a1");
        Write(a, "b.md", "b1");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "a.md", "a2");
        Sync(a);
        Write(b, "b.md", "b2");
        var result = Sync(b);
        Assert.True(result.Pulled);
        Assert.True(result.Pushed);
        Assert.Empty(result.Pending);
        Assert.Equal("a2", Read(b, "a.md"));
        Assert.Equal("b2", Read(b, "b.md"));
        Sync(a);
        Assert.Equal("b2", Read(a, "b.md"));
        Assert.StartsWith("同步：合并云端修改", NotebookGit.Log(b.WorkTree)[0]);
    }

    [Fact]
    public void SameLineEditedOnBothSidesAsksAndTouchesNothing()
    {
        var cloud = new Cloud(root);
        var (_, b) = Diverged(cloud);
        var before = CloudHead(cloud);
        var result = Sync(b);
        Assert.Equal(new[] { "note.md" }, result.Pending.Select(item => item.Path).ToArray());
        Assert.Equal("from b"u8.ToArray(), result.Pending[0].Local);
        Assert.Equal("from a"u8.ToArray(), result.Pending[0].Cloud);
        Assert.False(result.Pushed);
        Assert.False(result.Pulled);
        Assert.Equal("from b", Read(b, "note.md"));
        Assert.Equal("none", NotebookGit.RepositoryState(b.WorkTree));
        Assert.False(File.Exists(Path.Combine(b.WorkTree, ".git", "jitnote", "syncing")));
        Assert.Equal(before, CloudHead(cloud));
        Assert.True(b.HasUnsyncedWork());
    }

    [Fact]
    public void ChoosingTheLocalVersionKeepsItAndTheCloudVersionStaysInHistory()
    {
        var cloud = new Cloud(root);
        var (a, b) = Diverged(cloud);
        Assert.Single(Sync(b).Pending);
        var result = Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = Side.LOCAL });
        Assert.Empty(result.Pending);
        Assert.Equal(1, result.Resolved);
        Assert.True(result.Pushed);
        Assert.Equal("from b", Read(b, "note.md"));
        Sync(a);
        Assert.Equal("from b", Read(a, "note.md"));
        Assert.True(HistoryHas(a, "note.md", "from a"));
        Assert.StartsWith("同步：合并云端修改（1 个文件两边都改了", NotebookGit.Log(b.WorkTree)[0]);
    }

    [Fact]
    public void ChoosingTheCloudVersionTakesItAndTheLocalVersionStaysInHistory()
    {
        var cloud = new Cloud(root);
        var (a, b) = Diverged(cloud);
        var result = Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = Side.REMOTE });
        Assert.Empty(result.Pending);
        Assert.True(result.Pushed);
        Assert.Equal("from a", Read(b, "note.md"));
        Assert.True(HistoryHas(b, "note.md", "from b"));
        Sync(a);
        Assert.Equal("from a", Read(a, "note.md"));
    }

    [Fact]
    public void CancellingLeavesTheQuestionForTheNextSync()
    {
        var cloud = new Cloud(root);
        var (_, b) = Diverged(cloud);
        var before = CloudHead(cloud);
        Assert.Single(Sync(b).Pending);
        var again = Sync(b);
        Assert.Equal(new[] { "note.md" }, again.Pending.Select(item => item.Path).ToArray());
        Assert.Equal(before, CloudHead(cloud));
        Assert.Equal("from b", Read(b, "note.md"));
    }

    [Fact]
    public void OnlyTheFilesBothSidesChangedAreAsked()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "note.md", "base");
        Write(a, "mine.md", "m0");
        Write(a, "theirs.md", "t0");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "note.md", "from a");
        Write(a, "theirs.md", "t1");
        Sync(a);
        Write(b, "note.md", "from b");
        Write(b, "mine.md", "m1");
        var result = Sync(b);
        Assert.Equal(new[] { "note.md" }, result.Pending.Select(item => item.Path).ToArray());
        var done = Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = Side.REMOTE, ["unrelated.md"] = Side.LOCAL });
        Assert.Empty(done.Pending);
        Assert.Equal("from a", Read(b, "note.md"));
        Assert.Equal("m1", Read(b, "mine.md"));
        Assert.Equal("t1", Read(b, "theirs.md"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void DeletedOnOneSideAndEditedOnTheOtherAsksAndHonorsEitherChoice(bool keepEdit)
    {
        var cloud = new Cloud(Path.Combine(root, keepEdit ? "keep" : "delete"));
        var a = cloud.Device("a");
        Write(a, "note.md", "base");
        Sync(a);
        var b = cloud.Device("b");
        File.Delete(Path.Combine(a.WorkTree, "note.md"));
        Sync(a);
        Write(b, "note.md", "edited");
        var result = Sync(b);
        Assert.Equal("note.md", result.Pending[0].Path);
        Assert.Equal("edited"u8.ToArray(), result.Pending[0].Local);
        Assert.Null(result.Pending[0].Cloud);
        Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = keepEdit ? Side.LOCAL : Side.REMOTE });
        Sync(a);
        Assert.Equal(keepEdit, File.Exists(Path.Combine(b.WorkTree, "note.md")));
        Assert.Equal(keepEdit, File.Exists(Path.Combine(a.WorkTree, "note.md")));
        Assert.True(HistoryHas(b, "note.md", "edited"));
    }

    [Fact]
    public void DeletedLocallyAndEditedInTheCloudReportsTheDeletion()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "note.md", "base");
        Sync(a);
        var b = cloud.Device("b");
        Write(a, "note.md", "edited in the cloud");
        Sync(a);
        File.Delete(Path.Combine(b.WorkTree, "note.md"));
        var result = Sync(b);
        Assert.Null(result.Pending[0].Local);
        Assert.Equal("edited in the cloud"u8.ToArray(), result.Pending[0].Cloud);
        Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = Side.LOCAL });
        Assert.False(File.Exists(Path.Combine(b.WorkTree, "note.md")));
    }

    [Fact]
    public void RemovesConflictRecordsOfEarlierVersions()
    {
        var a = new Cloud(root).Device("a");
        var legacy = Path.Combine(a.WorkTree, ".git", "jitnote", "conflicts.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        File.WriteAllText(legacy, "[]");
        Write(a, "note.md", "x");
        Sync(a);
        Assert.False(File.Exists(legacy));
    }

    [Fact]
    public void RespectsGitignoreAndLeavesItUntouched()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, ".gitignore", "secret.txt\n");
        Write(a, "note.md", "hi");
        Sync(a);
        Write(a, "secret.txt", "do not upload");
        Sync(a);
        var b = cloud.Device("b");
        Assert.False(File.Exists(Path.Combine(b.WorkTree, "secret.txt")));
        Assert.Equal("secret.txt\n", Read(b, ".gitignore"));
        Assert.False(a.HasUnsyncedWork());
    }

    [Fact]
    public void HistoryAndRestore()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "dir/日记.md", "v1");
        a.CommitAll(Author, "a");
        Write(a, "dir/日记.md", "v2");
        a.CommitAll(Author, "a");
        var history = a.History("dir/日记.md");
        Assert.Equal(new[] { "编辑：日记", "新建：日记" }, history.Select(item => item.Message).ToArray());
        Assert.Equal("v1", System.Text.Encoding.UTF8.GetString(a.Read(history[^1].Commit, "dir/日记.md")!));
        a.Restore("dir/日记.md", history[^1].Commit, Author, "a");
        Assert.Equal("v1", Read(a, "dir/日记.md"));
        Assert.Equal(new[] { "编辑：日记", "新建：日记" }, NotebookGit.Log(a.WorkTree));
        Assert.True(a.HasLocalChanges());
        Sync(a);
        Assert.Equal("编辑：日记", NotebookGit.Log(a.WorkTree)[0]);
    }

    [Fact]
    public void RestoreKeepsTheTextThatWasNotSavedYet()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "日记.md", "v1");
        a.CommitAll(Author, "a");
        Write(a, "日记.md", "v2, never committed");
        Write(a, "other.md", "unrelated");
        var first = a.History("日记.md")[^1].Commit;
        a.Restore("日记.md", first, Author, "a");
        Assert.Equal("v1", Read(a, "日记.md"));
        var kept = a.History("日记.md")[0];
        Assert.Equal("v2, never committed", System.Text.Encoding.UTF8.GetString(a.Read(kept.Commit, "日记.md")!));
        Assert.Null(a.Read(kept.Commit, "other.md"));
    }

    [Fact]
    public void CommitPathsRecordsOnlyThosePaths()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "dir/x.md", "x1");
        Write(a, "keep.md", "k1");
        a.CommitAll(Author, "a");
        Write(a, "dir/x.md", "x2");
        Write(a, "dir/new.md", "new");
        Write(a, "dir/secret.txt", "ignored");
        Write(a, ".gitignore", "secret.txt\n");
        Write(a, "keep.md", "k2");
        Write(a, "a[1].md", "glob characters in a name");
        Write(a, "a1.md", "must not be matched by that glob");
        Assert.True(a.CommitPaths(new[] { "dir", "a[1].md" }, Author, "a"));
        var head = a.History("dir/x.md")[0].Commit;
        Assert.Equal("x2", System.Text.Encoding.UTF8.GetString(a.Read(head, "dir/x.md")!));
        Assert.Equal("new", System.Text.Encoding.UTF8.GetString(a.Read(head, "dir/new.md")!));
        Assert.Equal("glob characters in a name", System.Text.Encoding.UTF8.GetString(a.Read(head, "a[1].md")!));
        Assert.Null(a.Read(head, "dir/secret.txt"));
        Assert.Null(a.Read(head, "a1.md"));
        Assert.Equal("k1", System.Text.Encoding.UTF8.GetString(a.Read(head, "keep.md")!));
        Assert.True(a.HasLocalChanges());
        Assert.False(a.CommitPaths(new[] { "dir" }, Author, "a"));
    }

    [Fact]
    public void CommitPathsRecordsADeletedFolder()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "dir/x.md", "x1");
        a.CommitAll(Author, "a");
        Directory.Delete(Path.Combine(a.WorkTree, "dir"), true);
        Assert.True(a.CommitPaths(new[] { "dir" }, Author, "a"));
        Assert.Equal("删除：x", NotebookGit.Log(a.WorkTree)[0]);
        var history = a.History("dir/x.md");
        Assert.Null(a.Read(history[0].Commit, "dir/x.md"));
        Assert.Equal("x1", System.Text.Encoding.UTF8.GetString(a.Read(history[^1].Commit, "dir/x.md")!));
    }

    [Fact]
    public void DeletingANoteThatWasNeverCommittedKeepsItsText()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "base.md", "b");
        a.CommitAll(Author, "a");
        Write(a, "draft.md", "written a minute ago");
        a.CommitPaths(new[] { "draft.md" }, Author, "a");
        File.Delete(Path.Combine(a.WorkTree, "draft.md"));
        Sync(a);
        var history = a.History("draft.md");
        Assert.Equal(new[] { "删除：draft", "新建：draft" }, history.Select(item => item.Message).ToArray());
        Assert.Equal("written a minute ago", System.Text.Encoding.UTF8.GetString(a.Read(history[^1].Commit, "draft.md")!));
    }

    [Fact]
    public void RecoversFromInterruptedMerge()
    {
        var b = StartConflictingMerge(new Cloud(root));
        var marker = Path.Combine(b.WorkTree, ".git", "jitnote", "syncing");
        Directory.CreateDirectory(Path.GetDirectoryName(marker)!);
        File.WriteAllBytes(marker, Array.Empty<byte>());
        var asked = Sync(b);
        Assert.Equal(new[] { "note.md" }, asked.Pending.Select(item => item.Path).ToArray());
        Assert.Equal("none", NotebookGit.RepositoryState(b.WorkTree));
        Assert.False(File.Exists(marker));
        Sync(b, choices: new Dictionary<string, Side> { ["note.md"] = Side.LOCAL });
        Assert.False(b.HasUnsyncedWork());
    }

    [Fact]
    public void LeavesAnotherToolsUnfinishedMergeAlone()
    {
        var b = StartConflictingMerge(new Cloud(root));
        var conflicted = Read(b, "note.md");
        var failure = Assert.Throws<SyncException>(() => Sync(b));
        Assert.Contains("合并", failure.Message);
        Assert.Equal("merge", NotebookGit.RepositoryState(b.WorkTree));
        Assert.Equal(conflicted, Read(b, "note.md"));
        Assert.False(File.Exists(Path.Combine(b.WorkTree, ".git", "jitnote", "syncing")));
    }

    [Fact]
    public void WaitsForAnotherProgramsIndexLock()
    {
        var a = new Cloud(root).Device("a");
        Write(a, "note.md", "x");
        var lockFile = Path.Combine(a.WorkTree, ".git", "index.lock");
        File.WriteAllBytes(lockFile, Array.Empty<byte>());
        var previous = NotebookGit.IndexLockWaitSeconds;
        NotebookGit.IndexLockWaitSeconds = 0.3;
        try
        {
            var failure = Assert.Throws<SyncException>(() => Sync(a));
            Assert.Contains("稍后再同步", failure.Message);
            Assert.True(File.Exists(lockFile));
            Assert.True(a.HasLocalChanges());
            NotebookGit.IndexLockWaitSeconds = 5;
            Task.Run(async () =>
            {
                await Task.Delay(400);
                File.Delete(lockFile);
            });
            var result = Sync(a);
            Assert.True(result.Pushed);
        }
        finally
        {
            NotebookGit.IndexLockWaitSeconds = previous;
        }
    }

    [Fact]
    public void PushesACommitMadeByAnotherToolAsIs()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Write(a, "note.md", "written by an AI");
        a.CommitAll(new Author("AI", "ai@example.com"), "ai");
        var theirs = a.History("note.md")[0].Commit;
        var result = Sync(a);
        Assert.True(result.Pushed);
        Assert.Equal(new[] { "新建：note" }, NotebookGit.Log(a.WorkTree));
        Assert.Equal(new[] { theirs }, cloud.Device("c").History("note.md").Select(item => item.Commit).ToArray());
    }

    [Fact]
    public void MergesACommitMadeByAnotherToolWithoutRewritingIt()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        var b = cloud.Device("b");
        Write(a, "ai.md", "from the AI");
        a.CommitAll(new Author("AI", "ai@example.com"), "ai");
        var theirs = a.History("ai.md")[0].Commit;
        Write(b, "other.md", "from the cloud");
        Sync(b);
        var result = Sync(a);
        Assert.True(result.Pulled && result.Pushed);
        Assert.Equal("from the cloud", Read(a, "other.md"));
        Assert.Equal(new[] { theirs }, cloud.Device("c").History("ai.md").Select(item => item.Commit).ToArray());
    }

    [Fact]
    public void KeepsAnIdentityThatIsAlreadyConfigured()
    {
        var a = new Cloud(root).Device("a");
        NotebookGit.WriteConfig(a.WorkTree, "user.name", "Me");
        NotebookGit.WriteConfig(a.WorkTree, "user.email", "me@example.org");
        Write(a, "note.md", "x");
        Sync(a);
        Assert.Equal("Me", NotebookGit.ReadConfig(a.WorkTree, "user.name"));
        Assert.Equal("me@example.org", NotebookGit.ReadConfig(a.WorkTree, "user.email"));
    }

    [Fact]
    public void WritesAnIdentityForOtherToolsWhenNoneIsConfigured()
    {
        var a = new Cloud(root).Device("a");
        Assert.Null(NotebookGit.ReadConfig(a.WorkTree, "user.name"));
        Write(a, "note.md", "x");
        Sync(a);
        Assert.Equal("Tester", NotebookGit.ReadConfig(a.WorkTree, "user.name"));
        Assert.Equal("tester@example.com", NotebookGit.ReadConfig(a.WorkTree, "user.email"));
    }

    [Fact]
    public void UnsyncedWorkIsDetected()
    {
        var cloud = new Cloud(root);
        var a = cloud.Device("a");
        Assert.False(a.HasUnsyncedWork());
        Write(a, "note.md", "x");
        Assert.True(a.HasUnsyncedWork());
        a.CommitAll(Author, "a");
        Assert.True(a.HasUnsyncedWork());
        Sync(a);
        Assert.False(a.HasUnsyncedWork());
        Assert.Equal("origin", NotebookGit.ReadConfig(a.WorkTree, "branch.main.remote"));
    }

    [Fact]
    public void DescribesChanges()
    {
        Assert.Equal("新建：a", NotebookGit.DescribeChanges(new[] { "a.md" }, Array.Empty<string>(), Array.Empty<string>()));
        Assert.Equal("编辑：b", NotebookGit.DescribeChanges(Array.Empty<string>(), new[] { "x/b.md" }, Array.Empty<string>()));
        Assert.Equal("删除：c.txt", NotebookGit.DescribeChanges(Array.Empty<string>(), Array.Empty<string>(), new[] { "c.txt" }));
        Assert.Equal("重命名：a → b", NotebookGit.DescribeChanges(new[] { "b.md" }, Array.Empty<string>(), new[] { "a.md" }));
        var none = Array.Empty<string>();
        Assert.Equal("重命名：a → b", NotebookGit.DescribeChanges(new[] { "x/b.md" }, none, new[] { "x/a.md" }));
        Assert.Equal("移动：读书笔记 → 工作/项目", NotebookGit.DescribeChanges(new[] { "工作/项目/读书笔记.md" }, none, new[] { "读书笔记.md" }));
        Assert.Equal("移动：读书笔记 → 根目录", NotebookGit.DescribeChanges(new[] { "读书笔记.md" }, none, new[] { "工作/读书笔记.md" }));
        Assert.Equal("重命名：a → 工作/b", NotebookGit.DescribeChanges(new[] { "工作/b.md" }, none, new[] { "a.md" }));
        Assert.Equal("重命名：a → b", NotebookGit.DescribeChanges(new[] { "b.md" }, none, new[] { "x/a.md" }));
        Assert.Equal(
            "移动：会议记录 → 工作",
            NotebookGit.DescribeChanges(new[] { "工作/会议记录/a.md", "工作/会议记录/img/b.png" }, none, new[] { "会议记录/a.md", "会议记录/img/b.png" }));
        Assert.Equal(
            "移动：会议记录 → 根目录",
            NotebookGit.DescribeChanges(new[] { "会议记录/a.md", "会议记录/b.md" }, none, new[] { "工作/会议记录/a.md", "工作/会议记录/b.md" }));
        // A folder renamed in place, files moved out of a folder one by one, or a move with edits: not a folder move.
        Assert.Equal("更新 4 个文件：a、b", NotebookGit.DescribeChanges(new[] { "y/a.md", "y/b.md" }, none, new[] { "x/a.md", "x/b.md" }));
        Assert.Equal("更新 4 个文件：a、b", NotebookGit.DescribeChanges(new[] { "工作/a.md", "工作/b.md" }, none, new[] { "a.md", "b.md" }));
        Assert.Equal("更新 3 个文件：c、a", NotebookGit.DescribeChanges(new[] { "新/a.md" }, new[] { "c.md" }, new[] { "旧/a.md" }));
        Assert.Equal("更新 4 个文件：a、b、c 等", NotebookGit.DescribeChanges(new[] { "c.md", "d.md" }, new[] { "a.md", "b.md" }, Array.Empty<string>()));
        Assert.Null(NotebookGit.DescribeChanges(Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>()));
    }

    [Fact]
    public void ClassifiesErrorsForPeople()
    {
        Assert.Equal(SyncErrorKind.Auth, NotebookGit.Classify(new Exception("too many redirects or authentication replays")).Kind);
        Assert.Equal(SyncErrorKind.Auth, NotebookGit.Classify(new Exception("unexpected http status code: 403")).Kind);
        Assert.Equal(SyncErrorKind.Auth, NotebookGit.Classify(new Exception("x"), -16).Kind);
        Assert.Equal(SyncErrorKind.Network, NotebookGit.Classify(new Exception("failed to resolve address for gitee.com: nodename nor servname provided")).Kind);
        Assert.Equal(SyncErrorKind.Network, NotebookGit.Classify(new Exception("failed to connect to 10.0.0.1: Connection refused")).Kind);
        Assert.Equal(SyncErrorKind.NotFound, NotebookGit.Classify(new Exception("unexpected http status code: 404")).Kind);
        Assert.Equal(SyncErrorKind.NotFound, NotebookGit.Classify(new Exception("https://x/y.git: Repository not found")).Kind);
        var certificate = NotebookGit.Classify(new Exception("the SSL certificate is invalid"), -17);
        Assert.Contains("安全证书", certificate.Message);
    }
}
