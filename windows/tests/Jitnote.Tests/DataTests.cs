using System.Text.Json;
using Xunit;

namespace Jitnote.Tests;

public class NoteTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "jitnote-notes", Guid.NewGuid().ToString("n"));
    public NoteTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);

    static void Write(string root, string path, string text = "", long? modifiedMs = null)
    {
        var file = Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, text);
        if (modifiedMs != null)
            File.SetLastWriteTimeUtc(file, DateTimeOffset.FromUnixTimeMilliseconds(modifiedMs.Value).UtcDateTime);
    }

    [Fact]
    public void BuildsTheFileTreeLikeObsidian()
    {
        Write(root, "b.md");
        Write(root, "A.txt");
        Write(root, "会议/2026/x.md");
        Write(root, "会议/2026/y.md");
        Write(root, "会议/2025/z.md");
        Write(root, "会议/议程.md");
        Write(root, "技术/安卓/发布/r.md");
        Write(root, "附件/cat.png");
        Directory.CreateDirectory(Path.Combine(root, "空文件夹"));
        Write(root, ".obsidian/w.md");
        Write(root, ".gitignore", "x");
        var tree = NoteIndex.Tree(root);
        Assert.Equal(new[] { "附件", "会议", "技术", "空文件夹", "A.txt", "b.md" }, tree.Select(item => item.Name).ToArray());
        var meetings = tree[1];
        Assert.True(meetings.IsFolder);
        Assert.Equal(4, meetings.NoteCount);
        Assert.Equal(new[] { "2025", "2026", "议程.md" }, meetings.Children.Select(item => item.Name).ToArray());
        Assert.Equal("会议/2026", meetings.Children[1].Path);
        Assert.Equal(2, meetings.Children[1].NoteCount);
        Assert.Equal(new[] { "cat.png" }, tree[0].Children.Select(item => item.Name).ToArray());
        Assert.Equal(0, tree[0].NoteCount);
        Assert.Empty(tree[3].Children);
        Assert.Equal(new[] { "r.md" }, tree[2].Children[0].Children[0].Children.Select(item => item.Name).ToArray());
    }

    [Fact]
    public void TreeSortsByNameBothWays()
    {
        Write(root, "b.md");
        Write(root, "a.md");
        Write(root, "乙/x.md");
        Write(root, "甲/x.md");
        Assert.Equal(new[] { "甲", "乙", "a.md", "b.md" }, NoteIndex.Tree(root, NoteSort.TITLE_ASC).Select(item => item.Name).ToArray());
        Assert.Equal(new[] { "乙", "甲", "b.md", "a.md" }, NoteIndex.Tree(root, NoteSort.TITLE_DESC).Select(item => item.Name).ToArray());
    }

    [Fact]
    public void TreeSortsFilesByMinuteAndKeepsFoldersByName()
    {
        Write(root, "a.md", modifiedMs: 60_000);
        Write(root, "b.md", modifiedMs: 180_000);
        Write(root, "c.md", modifiedMs: 120_000);
        Write(root, "乙/x.md");
        Write(root, "甲/x.md");
        Assert.Equal(new[] { "甲", "乙", "b.md", "c.md", "a.md" }, NoteIndex.Tree(root, NoteSort.MODIFIED_DESC).Select(item => item.Name).ToArray());
        Assert.Equal(new[] { "甲", "乙", "a.md", "c.md", "b.md" }, NoteIndex.Tree(root, NoteSort.MODIFIED_ASC).Select(item => item.Name).ToArray());
    }

    [Fact]
    public void TreeBreaksTiesInTheSameMinuteByName()
    {
        Write(root, "b.md", modifiedMs: 60_000);
        Write(root, "a.md", modifiedMs: 60_030);
        Assert.Equal(new[] { "a.md", "b.md" }, NoteIndex.Tree(root, NoteSort.MODIFIED_DESC).Select(item => item.Name).ToArray());
    }

    [Fact]
    public void HiddenFilesOnlyWhenAskedAndNeverGit()
    {
        Write(root, "a.md");
        Write(root, ".gitignore", "x");
        Write(root, ".obsidian/templates/模板.md");
        Write(root, ".git/notes.md");
        Assert.Equal(new[] { "a.md" }, NoteIndex.Tree(root).Select(item => item.Name).ToArray());
        var tree = NoteIndex.Tree(root, showHidden: true);
        Assert.Equal(new[] { ".obsidian", ".gitignore", "a.md" }, tree.Select(item => item.Name).ToArray());
        Assert.Equal(1, tree[0].NoteCount);
    }

    [Fact]
    public void SymlinkIsListedUnderItsOwnName()
    {
        Write(root, "AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "project_memory.md"), "AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "CLAUDE.md"), "@AGENTS.md");
        var tree = NoteIndex.Tree(root);
        Assert.Equal(new[] { "AGENTS.md", "CLAUDE.md", "project_memory.md" }, tree.Select(item => item.Name).ToArray());
        Assert.Equal(new[] { "AGENTS.md", "CLAUDE.md", "project_memory.md" }, tree.Select(item => item.Path).ToArray());
    }

    [Fact]
    public void ReferenceOpensTheFileItPointsAt()
    {
        Write(root, "AGENTS.md", "rules");
        Write(root, "其他.md", "other");
        File.CreateSymbolicLink(Path.Combine(root, "CLAUDE.md"), "@AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "project_memory.md"), "AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "跳转.md"), "@CLAUDE.md");
        File.CreateSymbolicLink(Path.Combine(root, "断了.md"), "@没有.md");
        File.CreateSymbolicLink(Path.Combine(root, "出去.md"), "/etc/passwd");
        Directory.CreateDirectory(Path.Combine(root, "子目录"));
        File.CreateSymbolicLink(Path.Combine(root, "子目录", "索引.md"), "@../AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "子目录", "快捷方式.md"), "../AGENTS.md");
        File.CreateSymbolicLink(Path.Combine(root, "甲.md"), "@乙.md");
        File.CreateSymbolicLink(Path.Combine(root, "乙.md"), "@甲.md");
        Assert.Equal("AGENTS.md", NoteIndex.ResolveReference(Path.Combine(root, "CLAUDE.md"), root));
        Assert.Equal("AGENTS.md", NoteIndex.ResolveReference(Path.Combine(root, "project_memory.md"), root));
        Assert.Equal("AGENTS.md", NoteIndex.ResolveReference(Path.Combine(root, "跳转.md"), root));
        Assert.Equal("AGENTS.md", NoteIndex.ResolveReference(Path.Combine(root, "子目录", "索引.md"), root));
        Assert.Equal("AGENTS.md", NoteIndex.ResolveReference(Path.Combine(root, "子目录", "快捷方式.md"), root));
        Assert.Null(NoteIndex.ResolveReference(Path.Combine(root, "AGENTS.md"), root));
        Assert.Null(NoteIndex.ResolveReference(Path.Combine(root, "断了.md"), root));
        Assert.Null(NoteIndex.ResolveReference(Path.Combine(root, "出去.md"), root));
        Assert.Null(NoteIndex.ResolveReference(Path.Combine(root, "甲.md"), root));
        Assert.Equal("AGENTS.md", NoteIndex.ReferenceTarget("", root, false));
        Assert.Equal("AGENTS.md", NoteIndex.ReferenceTarget("子目录", root, false));
    }

    [Fact]
    public void ImagesStayInsideTheNotebook()
    {
        var book = Path.Combine(root, "notebook");
        foreach (var path in new[] { "日记/assets/my photo.png", "附件/封面.png", "附件/深/封面.png", "图库/2026/封面.png", ".git/objects/封面.png" })
            Write(book, path, "x");
        Write(root, "outside.png", "x");
        var assets = new NoteAssets(book);
        Assert.Equal("日记/assets/my photo.png", assets.Resolve("日记", "assets/my photo.png"));
        Assert.Equal("日记/assets/my photo.png", assets.Resolve("日记", "./assets/my photo.png"));
        Assert.Equal("附件/封面.png", assets.Resolve("日记", "附件/封面.png"));
        Assert.Equal("附件/封面.png", assets.Resolve("日记", "/附件/封面.png"));
        Assert.Equal("附件/封面.png", assets.Resolve("日记", "封面.png"));
        Assert.Equal("图库/2026/封面.png", assets.Resolve("", "2026/封面.png"));
        Assert.Equal("日记/assets/my photo.png", assets.Resolve("", "MY PHOTO.png"));
        Assert.Null(assets.Resolve("日记", "../../outside.png"));
        Assert.Null(assets.Resolve("", "outside.png"));
        Assert.Null(assets.Resolve("", "objects/封面.png"));
        Assert.Null(assets.Resolve("", "https://example.com/a.png"));
        Assert.Null(assets.Resolve("", "missing.png"));
        Assert.True(NoteAssets.IsImage("cat.png"));
        Assert.False(NoteAssets.IsImage("note.md"));
    }

    string ImageNotebook()
    {
        var book = Path.Combine(root, "notebook");
        Write(book, "笔记/a.md", "![封面](img/a.png)");
        Write(book, "笔记/img/a.png", "x");
        Write(book, "日志/b.md", "![](../笔记/img/a.png)");
        Write(book, "c.md", "![](/笔记/img/a.png)");
        Write(book, "d.md", "![](https://example.com/x.png) ![[a.png]] ![](missing.png)");
        Write(book, "e.md", "![](my%20photo.png) ![](<my photo.png>)");
        Write(book, "my photo.png", "x");
        Write(book, "g.md", "```\n![](root.png)\n```");
        Write(book, "root.png", "x");
        return book;
    }

    [Fact]
    public void CanMoveOnlyToAnotherPlaceOutsideItself()
    {
        Assert.True(FileTree.CanMove("a/b.md", ""));
        Assert.True(FileTree.CanMove("b.md", "a"));
        Assert.False(FileTree.CanMove("a/b.md", "a"));
        Assert.False(FileTree.CanMove("b.md", ""));
        Assert.False(FileTree.CanMove("a", "a"));
        Assert.False(FileTree.CanMove("a", "a/c"));
        Assert.True(FileTree.CanMove("a", "ab"));
        Assert.True(FileTree.CanMove("a/b", ""));
    }

    string Full(string path) => Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));

    [Fact]
    public void MovesAFileIntoAFolder()
    {
        Write(root, "a.md", "内容");
        Directory.CreateDirectory(Full("工作"));
        var moved = NoteFiles.Move(Full("a.md"), Full("工作"));
        Assert.Equal(Full("工作/a.md"), moved);
        Assert.Equal("内容", File.ReadAllText(moved));
        Assert.False(File.Exists(Full("a.md")));
    }

    [Fact]
    public void MovesAFolderWithEverythingInside()
    {
        Write(root, "会议/2026/x.md", "纪要");
        Directory.CreateDirectory(Full("工作"));
        NoteFiles.Move(Full("会议"), Full("工作"));
        Assert.Equal("纪要", File.ReadAllText(Full("工作/会议/2026/x.md")));
        Assert.False(Directory.Exists(Full("会议")));
    }

    [Fact]
    public void MovesToTheNotebookRoot()
    {
        Write(root, "工作/a.md");
        NoteFiles.Move(Full("工作/a.md"), root);
        Assert.True(File.Exists(Full("a.md")));
    }

    [Fact]
    public void RefusesToMoveWhenTheNameIsTaken()
    {
        Write(root, "a.md", "新");
        Write(root, "工作/a.md", "旧");
        var error = Assert.Throws<SyncException>(() => NoteFiles.Move(Full("a.md"), Full("工作")));
        Assert.Equal("目标文件夹里已有同名文件", error.Message);
        Assert.Equal("新", File.ReadAllText(Full("a.md")));
        Assert.Equal("旧", File.ReadAllText(Full("工作/a.md")));
    }

    [Fact]
    public void AFolderCannotGoIntoItself()
    {
        Write(root, "会议/2026/x.md");
        Assert.Throws<SyncException>(() => NoteFiles.Move(Full("会议"), Full("会议/2026")));
        Assert.Throws<SyncException>(() => NoteFiles.Move(Full("会议"), Full("会议")));
        Assert.True(File.Exists(Full("会议/2026/x.md")));
    }

    [Fact]
    public void MovingToWhereItIsChangesNothing()
    {
        Write(root, "a.md", "内容");
        NoteFiles.Move(Full("a.md"), root);
        Assert.Equal("内容", File.ReadAllText(Full("a.md")));
    }

    [Fact]
    public void BrokenImagesWhenANoteMovesAwayFromItsImages()
    {
        var book = ImageNotebook();
        Assert.Equal(new[] { "笔记/a.md" }, BrokenImageCheck.Notes(book, "笔记/a.md", "工作"));
    }

    [Fact]
    public void BrokenImagesWhenAFolderMovesTogetherWithItsImages()
    {
        var book = ImageNotebook();
        // Only the notes that point into the folder from outside lose their image.
        Assert.Equal(new[] { "c.md", "日志/b.md" }, BrokenImageCheck.Notes(book, "笔记", "工作"));
        Assert.Empty(BrokenImageCheck.Notes(book, "笔记", ""));
    }

    [Fact]
    public void BrokenImagesWhenAnImageMovesAwayFromItsNotes()
    {
        var book = ImageNotebook();
        Assert.Equal(new[] { "c.md", "日志/b.md", "笔记/a.md" }, BrokenImageCheck.Notes(book, "笔记/img/a.png", ""));
        Assert.Equal(new[] { "e.md" }, BrokenImageCheck.Notes(book, "my photo.png", "工作"));
    }

    [Fact]
    public void BrokenImagesFollowParentFolderReferences()
    {
        var book = ImageNotebook();
        Assert.Empty(BrokenImageCheck.Notes(book, "日志/b.md", "工作"));
        Assert.Empty(BrokenImageCheck.Notes(book, "日志/b.md", "笔记"));
        Assert.Equal(new[] { "日志/b.md" }, BrokenImageCheck.Notes(book, "日志/b.md", "工作/深"));
        Assert.Empty(BrokenImageCheck.Notes(book, "c.md", "笔记"));
    }

    [Fact]
    public void BrokenImagesCountOncePerNoteAndOnlyIfTheyWorkedBefore()
    {
        var book = ImageNotebook();
        Assert.Equal(new[] { "e.md" }, BrokenImageCheck.Notes(book, "e.md", "工作"));
        Assert.Empty(BrokenImageCheck.Notes(book, "d.md", "工作"));
        Assert.Empty(BrokenImageCheck.Notes(book, "root.png", "工作"));
    }

    [Fact]
    public void BrokenImageCheckReadsOnly()
    {
        var book = ImageNotebook();
        Dictionary<string, string> Snapshot() =>
            Directory.EnumerateFiles(book, "*", SearchOption.AllDirectories).ToDictionary(file => file, File.ReadAllText);
        var before = Snapshot();
        BrokenImageCheck.Notes(book, "笔记", "工作");
        Assert.Equal(before, Snapshot());
    }

    [Fact]
    public void AnUneditedNoteIsNeverWritten()
    {
        var file = Path.Combine(root, "note.md");
        File.WriteAllText(file, "# 原文\r\n  odd   spacing");
        var before = File.ReadAllBytes(file);
        var saver = new NoteSaver(file, "# 原文\r\n  odd   spacing");
        Assert.False(saver.Save("# 原文\n\nodd spacing\n"));
        Assert.Equal(before, File.ReadAllBytes(file));
    }

    [Fact]
    public void AnEditedNoteIsWrittenOnceAndADeletedNoteIsNotBroughtBack()
    {
        var file = Path.Combine(root, "note.md");
        File.WriteAllText(file, "v1");
        var saver = new NoteSaver(file, "v1");
        saver.MarkEdited();
        Assert.True(saver.Save("v2"));
        Assert.False(saver.Save("v2"));
        Assert.False(saver.ChangedOnDisk(File.ReadAllText(file)));
        File.WriteAllText(file, "written by an AI");
        Assert.True(saver.ChangedOnDisk("written by an AI"));
        saver.Adopt("written by an AI");
        Assert.False(saver.Save("something the old edit left behind"));
        Assert.Equal("written by an AI", File.ReadAllText(file));
        File.Delete(file);
        saver.MarkEdited();
        Assert.False(saver.Save("typed just before it vanished"));
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void NewNoteAndFolderRejectHiddenNames()
    {
        var file = NoteFiles.CreateNote(root, "日记");
        Assert.Equal("# 日记\n\n", File.ReadAllText(file));
        Assert.Throws<SyncException>(() => NoteFiles.CreateNote(root, ".secret"));
        var folder = NoteFiles.CreateFolder(root, "会议");
        Assert.True(Directory.Exists(folder));
        var renamed = NoteFiles.Rename(file, "周记");
        Assert.EndsWith("周记.md", renamed);
    }
}

public class FolderRuleTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "jitnote-folders", Guid.NewGuid().ToString("n"));
    public FolderRuleTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);

    static void Make(string path, params string[] files)
    {
        Directory.CreateDirectory(path);
        foreach (var file in files) File.WriteAllText(Path.Combine(path, file), "x");
    }

    [Fact]
    public void DefaultPlaceAndEmptyRules()
    {
        Assert.Equal("my-notes", Path.GetFileName(NotebookFolders.DefaultFolder("my-notes", root)));
        Make(Path.Combine(root, "my-notes"), "a.md");
        Make(Path.Combine(root, "my-notes 2"), "b.md");
        Make(Path.Combine(root, "my-notes 3"));
        Assert.Equal("my-notes 3", Path.GetFileName(NotebookFolders.DefaultFolder("my-notes", root)));
        Assert.Null(NotebookFolders.Problem(Path.Combine(root, "missing")));
        var empty = Path.Combine(root, "empty");
        Make(empty, ".DS_Store", "desktop.ini", "Thumbs.db");
        Assert.Null(NotebookFolders.Problem(empty));
        var busy = Path.Combine(root, "busy");
        Make(busy, "a.md");
        Assert.Contains("不是空的", NotebookFolders.Problem(busy));
        Assert.Contains("文件", NotebookFolders.Problem(Path.Combine(busy, "a.md")));
        Assert.True(NotebookFolders.IsInDefaultRoot(Path.Combine(root, "x"), root));
        Assert.False(NotebookFolders.IsInDefaultRoot(Path.Combine(root, "a", "x"), root));
        Assert.Equal("a-b-c", NotebookFolders.FolderName("a/b:c"));
        Assert.Equal("hidden", NotebookFolders.FolderName(".hidden"));
        Assert.Equal("笔记本", NotebookFolders.FolderName("  "));
    }

    [Fact]
    public void WarnsAboutCloudSyncFoldersAndRefusesNestedNotebooks()
    {
        var home = "/Users/someone";
        foreach (var path in new[]
        {
            "Library/Mobile Documents/com~apple~CloudDocs/notes",
            "Library/CloudStorage/Dropbox/notes",
            "Dropbox/notes",
            "OneDrive - Company/notes",
            "Google Drive/notes",
        })
            Assert.NotNull(NotebookFolders.SyncWarning(Path.Combine(home, path)));
        Assert.Null(NotebookFolders.SyncWarning(Path.Combine(home, "Jitnote/notes")));
        Assert.Null(NotebookFolders.SyncWarning(Path.Combine(home, "Projects/dropbox-clone")));
        var notebook = Path.Combine(root, "notebook");
        Make(Path.Combine(notebook, "sub"));
        Assert.Contains("另一个笔记本", NotebookFolders.Problem(Path.Combine(notebook, "sub"), new[] { notebook }));
    }

    [Fact]
    public void MissingAndRelocationAndFailedDownload()
    {
        Assert.True(NotebookFolders.IsMissing(Path.Combine(root, "never-there")));
        var empty = Path.Combine(root, "empty");
        Make(empty);
        Assert.True(NotebookFolders.IsMissing(empty));
        NotebookGit.InitBareMain(Path.Combine(root, "cloud.git"));
        var moved = NotebookGit.Clone(Path.Combine(root, "cloud.git"), Path.Combine(root, "moved"), null);
        Assert.False(NotebookFolders.IsMissing(moved.WorkTree));
        Assert.Null(NotebookFolders.RelocationProblem(moved.WorkTree, moved.OriginUrl(), Path.Combine(root, "cloud.git").ToUpperInvariant() + "/", Array.Empty<string>()));
        Assert.Contains("另一个笔记本", NotebookFolders.RelocationProblem(moved.WorkTree, moved.OriginUrl(), "https://example.com/else.git", Array.Empty<string>()));
        var drive = Path.Combine(root, "Volumes", "unplugged");
        var target = Path.Combine(drive, "notes");
        Assert.Contains("外置硬盘", NotebookFolders.RedownloadProblem(target, false));
        Assert.Null(NotebookFolders.RedownloadProblem(target, true));
        var chosen = Path.Combine(root, "chosen");
        Make(chosen);
        Assert.ThrowsAny<Exception>(() => NotebookGit.Clone(Path.Combine(root, "no-such-repo.git"), chosen, null));
        Assert.True(Directory.Exists(chosen));
        Assert.Empty(Directory.GetFileSystemEntries(chosen));
        var made = Path.Combine(root, "made-by-download");
        Assert.ThrowsAny<Exception>(() => NotebookGit.Clone(Path.Combine(root, "no-such-repo.git"), made, null));
        Assert.False(Directory.Exists(made));
    }

    [Fact]
    public void AutoSyncOnColdStartOnlyOnceAndAfterAMinuteAway()
    {
        Assert.True(AutoSync.ShouldStart(true, false, true, null, false));
        Assert.False(AutoSync.ShouldStart(true, false, true, null, true));
        Assert.False(AutoSync.ShouldStart(true, false, true, AutoSync.MinAwayMs - 1, true));
        Assert.True(AutoSync.ShouldStart(true, false, true, AutoSync.MinAwayMs, true));
        Assert.False(AutoSync.ShouldStart(false, false, true, null, false));
        Assert.False(AutoSync.ShouldStart(true, true, true, null, false));
        Assert.False(AutoSync.ShouldStart(true, false, false, null, false));
    }

    [Fact]
    public void OldStateKeepsAccountsAndLeavesTheTokenOut()
    {
        var json = """
        {
          "accounts": [{"id":"a1","provider":"GITHUB","login":"me","email":"me@example.com","createdAt":1}],
          "notebooks": [{"id":"n1","name":"笔记","accountId":"a1","remoteUrl":"https://github.com/me/notes.git","dir":"notes","createdAt":2}],
          "currentNotebookId": "n1",
          "noteSort": "MODIFIED_DESC",
          "showHiddenFiles": true
        }
        """;
        var state = JsonSerializer.Deserialize<AppState>(json, AppJson.Options)!;
        Assert.Single(state.Accounts);
        Assert.Single(state.Notebooks);
        Assert.Equal("n1", state.CurrentNotebookId);
        Assert.True(state.ShowHiddenFiles);
        Assert.False(state.SyncOnLaunch);
        Assert.Equal(NoteSort.TITLE_ASC, state.FileSort);
        Assert.Equal(ViewMode.EDIT, state.DefaultViewMode);
        var old = """{"id":"n1","name":"读书","accountId":"a","remoteUrl":"https://x/y.git","dir":"n1","createdAt":5,"lastSyncAt":9}""";
        var notebook = JsonSerializer.Deserialize<Notebook>(old, AppJson.Options)!;
        Assert.Null(notebook.FolderPath);
        Assert.False(notebook.FolderChosen);
        Assert.Equal(9, notebook.LastSyncAt);
        var storePath = Path.Combine(root, "state.json");
        var store = new StateStore(storePath);
        store.Update(s => s.Accounts.Add(new Account { Id = "a1", Login = "me", Provider = Provider.GITHUB }));
        var tokens = new FileTokenStore(Path.Combine(root, "tokens.json"));
        tokens.Save("a1", "ghp_secret_token");
        var written = File.ReadAllText(storePath);
        Assert.DoesNotContain("ghp_secret_token", written);
        Assert.Equal("ghp_secret_token", tokens.Load("a1"));
        tokens.Delete("a1");
        Assert.Null(tokens.Load("a1"));
    }
}

public class HostingAndUpdateTests
{
    [Fact]
    public void ReadsRepositoriesAndNormalizesAddresses()
    {
        var repos = HostingApi.ParseRepos(JsonDocument.Parse("""
        [{
          "path": "notes", "name": "我的笔记", "owner": {"login": "zhl"},
          "namespace": {"path": "zhl"}, "description": "", "private": true,
          "html_url": "https://gitee.com/zhl/notes.git",
          "pushed_at": "2026-10-28T10:00:00+08:00"
        }, {
          "path": "jitnote-ab12", "name": "jitnote-ab12", "owner": {"login": "zhl"},
          "description": "[Jitnote] 读书笔记", "private": true,
          "html_url": "https://gitee.com/zhl/jitnote-ab12.git"
        }]
        """).RootElement);
        Assert.Equal("notes", repos[0].Path);
        Assert.Equal("我的笔记", repos[0].DisplayName);
        Assert.Equal("https://gitee.com/zhl/notes.git", repos[0].CloneUrl);
        Assert.False(repos[0].IsNotebook);
        Assert.True(repos[0].IsPrivate);
        Assert.Equal("zhl", repos[0].Owner);
        Assert.Equal(1_793_152_800_000, repos[0].UpdatedAt);
        Assert.True(repos[1].IsNotebook);
        Assert.Equal("读书笔记", repos[1].DisplayName);
        var github = HostingApi.ParseRepos(JsonDocument.Parse("""
        [{"name":"notes","owner":{"login":"acme"},"private":false,"html_url":"https://github.com/acme/notes","clone_url":"https://github.com/acme/notes.git","description":null,"size":204800}]
        """).RootElement)[0];
        Assert.Equal("notes", github.DisplayName);
        Assert.False(github.IsPrivate);
        Assert.Equal(204800, github.SizeKb);
        Assert.Equal("https://gitee.com/zhl/notes.git", RepoUrls.ToCloneUrl(" https://gitee.com/zhl/notes/tree/master/日记 "));
        Assert.Equal("https://github.com/a/b.git", RepoUrls.ToCloneUrl("https://www.github.com/a/b.git/"));
        Assert.Equal("https://git.example.com/team/notes", RepoUrls.ToCloneUrl("https://git.example.com/team/notes"));
        Assert.Equal("work-notes", RepoNames.FromName("Work Notes"));
        Assert.StartsWith("notes-", RepoNames.FromName("读书笔记"));
        Assert.True(RepoNames.IsValid("notes-ab12"));
        Assert.False(RepoNames.IsValid("1notes"));
        Assert.Equal(RepoUrls.Key("https://GitHub.com/a/b.git/"), RepoUrls.Key("https://github.com/a/b"));
    }

    [Fact]
    public void ComparesVersionsAndSpacesChecksOutByADay()
    {
        Assert.True(AppUpdates.IsNewer("v0.2.0", "0.1.0"));
        Assert.True(AppUpdates.IsNewer("0.10.0", "0.9.3"));
        Assert.True(AppUpdates.IsNewer("1.0", "0.9.9"));
        Assert.False(AppUpdates.IsNewer("v0.1.0", "0.1.0"));
        Assert.False(AppUpdates.IsNewer("not-a-version", "0.1.0"));
        Assert.False(AppUpdates.IsDue(AppJson.NowMillis(), AppJson.NowMillis()));
        Assert.True(AppUpdates.IsDue(null, AppJson.NowMillis()));
    }

    /// <summary>SHA-256 of the five bytes "hello".</summary>
    const string ShaOfHello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

    static readonly string Manifest = $$"""
    {
      "format": 1, "version": "0.11.0", "notes": "· Windows\r\n· 修复同步偶尔失败\n",
      "packages": {
        "android": {"name": "jitnote-0.11.0.apk", "size": 1, "sha256": "{{ShaOfHello}}",
                    "gitee": "https://gitee.com/a.apk", "github": "https://github.com/a.apk"},
        "windows-x64": {
          "name": "Jitnote-windows-x64-0.11.0.exe", "size": 97911742, "sha256": "{{ShaOfHello}}",
          "gitee": "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/Jitnote-windows-x64-0.11.0.exe",
          "github": "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/Jitnote-windows-x64-0.11.0.exe"
        }
      }
    }
    """;

    [Fact]
    public void ReadsTheWindowsPackageFromLatestJson()
    {
        var release = AppUpdates.ParseManifest(Manifest)!;
        Assert.Equal("0.11.0", release.Version);
        Assert.Equal("· Windows\n· 修复同步偶尔失败", release.Notes);
        // Gitee first: it is the fast one for most users; GitHub is the fallback.
        Assert.Equal(new[]
        {
            "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/Jitnote-windows-x64-0.11.0.exe",
            "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/Jitnote-windows-x64-0.11.0.exe",
        }, release.DownloadUrls);
        Assert.Equal(97911742, release.Size);
        Assert.Equal(ShaOfHello, release.Sha256);
    }

    [Fact]
    public void RejectsUnreadableLatestJsonAndIgnoresIncompletePackages()
    {
        Assert.Throws<InvalidDataException>(() => AppUpdates.ParseManifest("<html>Not Found</html>"));
        Assert.Throws<InvalidDataException>(() => AppUpdates.ParseManifest("""{"packages": {}}"""));
        Assert.Null(AppUpdates.ParseManifest("""{"version": "0.11.0", "packages": {}}"""));
        Assert.Null(AppUpdates.ParseManifest(Manifest, "windows-arm64"));
        Assert.Null(AppUpdates.ParseManifest(Manifest.Replace(ShaOfHello, "nope")));
    }

    [Fact]
    public async Task TakesTheFirstAnswerWithoutCancellingTheOther()
    {
        var slowFinished = new TaskCompletionSource();
        var result = await AppUpdates.FirstSuccess(new List<Func<Task<string>>>
        {
            () => throw new HttpRequestException("Gitee unreachable"),
            async () => { await Task.Delay(50); return "github"; },
            async () => { await Task.Delay(300); slowFinished.SetResult(); return "slow"; },
        });
        Assert.Equal("github", result);
        // The slow request still runs to the end: GitHub counts it as a download.
        await slowFinished.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task FailsOnlyWhenEverySiteFailed()
    {
        await Assert.ThrowsAsync<TimeoutException>(() => AppUpdates.FirstSuccess(new List<Func<Task<string>>>
        {
            () => throw new HttpRequestException("a"),
            async () => { await Task.Delay(20); throw new TimeoutException("b"); },
        }));
    }

    [Fact]
    public async Task KeepsOnlyADownloadWithTheRightChecksum()
    {
        var file = Path.Combine(Path.GetTempPath(), "jitnote-update-" + Guid.NewGuid().ToString("n") + ".exe");
        var tried = new List<string>();
        // Gitee hands out a different file, GitHub the right one: GitHub's is kept.
        await AppUpdates.DownloadVerified(["gitee", "github"], file, 5, ShaOfHello, async (url, target) =>
        {
            tried.Add(url);
            await File.WriteAllTextAsync(target, url == "gitee" ? "HELLO" : "hello");
        });
        Assert.Equal(["gitee", "github"], tried);
        Assert.Equal("hello", File.ReadAllText(file));
        // Nothing matches: no file is left behind to open.
        await Assert.ThrowsAsync<IOException>(() => AppUpdates.DownloadVerified(["gitee", "github"], file, 5, ShaOfHello,
            (_, target) => File.WriteAllTextAsync(target, "HELLO")));
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void FileTreeRowsFollowTheHighlight()
    {
        NoteEntry File(string path) => new() { Path = path, Name = path.Split('/').Last(), IsFolder = false, Children = Array.Empty<NoteEntry>(), NoteCount = 0, Modified = 0 };
        NoteEntry Folder(string path, params NoteEntry[] children) => new() { Path = path, Name = path.Split('/').Last(), IsFolder = true, Children = children, NoteCount = 0, Modified = 0 };
        var tree = new[]
        {
            Folder("会议", Folder("会议/2026", File("会议/2026/周会.md"))),
            Folder("会议记录"),
            File("a.md"),
        };
        var rows = FileTree.VisibleRows(tree, new HashSet<string> { "会议" });
        Assert.Equal(new[] { "会议", "2026", "会议记录", "a.md" }, rows.Select(row => row.Entry.Name).ToArray());
        Assert.Equal(new[] { 0, 1, 0, 0 }, rows.Select(row => row.Depth).ToArray());
        Assert.Equal("会议/2026", FileTree.CurrentFolder(tree, "会议/2026"));
        Assert.Equal("会议/2026", FileTree.CurrentFolder(tree, "会议/2026/周会.md"));
        Assert.Equal("", FileTree.CurrentFolder(tree, "已删除/x.md"));
        Assert.Equal(new HashSet<string> { "工作", "工作/2026", "b" }, FileTree.Renamed(new HashSet<string> { "会议", "会议/2026", "b" }, "会议", "工作"));
        Assert.Equal("会议记录/x.md", FileTree.Moved("会议记录/x.md", "会议", "工作"));
        Assert.Equal(new HashSet<string> { "会议记录" }, FileTree.Removed(new HashSet<string> { "会议", "会议/2026", "会议记录" }, "会议"));
    }
}
