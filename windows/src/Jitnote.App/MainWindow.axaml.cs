using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Jitnote;

public partial class MainWindow : Window
{
    readonly Session session;
    readonly INoteSurface surface;
    string? shownPath;
    string? shownText;
    bool shownPreview;
    bool preview;
    bool filling = true;
    /// <summary>A picture tapped in the open note, notebook-relative. The note stays open underneath.</summary>
    string? coverImage;

    public MainWindow() : this(new Session(Session.DefaultDirectory())) { }

    public MainWindow(Session session)
    {
        this.session = session;
        InitializeComponent();
        surface = CreateSurface();
        EditorHost.Content = surface;
#if JITNOTE_WEBVIEW2
        if (surface is WebNoteSurface web) web.Shortcut += (key, shift) => DispatchShortcut((int)key, shift);
#endif
        surface.TextEdited += text =>
        {
            session.SetOpenText(text);
            session.EditorChanged(text);
        };
        surface.ImageTapped += OpenCover;
        Viewer.BackRequested += CloseCover;
        session.Changed += () => Dispatcher.UIThread.Post(Refresh);
        AddHandler(KeyDownEvent, OnKey, RoutingStrategies.Tunnel, handledEventsToo: true);
        AddNotebookButton.Click += (_, _) => ShowAddNotebook();
        SyncButton.Click += async (_, _) => await RunSync();
        SettingsButton.Click += (_, _) => ShowSettings();
        NewNoteButton.Click += (_, _) => AskName("新建笔记", "笔记名称", name => session.NewNote(name));
        NewFolderButton.Click += (_, _) => AskName("新建文件夹", "文件夹名称", name => session.NewFolder(name));
        ModeButton.Click += (_, _) => ToggleMode();
        HistoryButton.Click += (_, _) => ShowHistory();
        RenameButton.Click += (_, _) =>
        {
            if (session.OpenPath != null)
                AskName("重命名", "新名称", name => session.RenameItem(session.OpenPath, name));
        };
        DeleteButton.Click += async (_, _) => await ConfirmDelete();
        NotebookPicker.SelectionChanged += (_, _) =>
        {
            if (!filling && NotebookPicker.SelectedItem is Notebook notebook) session.Select(notebook);
        };
        Opened += async (_, _) =>
        {
            if (session.UpdateDue()) await OfferUpdate(false);
        };
        Activated += (_, _) => session.OnForeground();
        Deactivated += (_, _) =>
        {
            session.Flush();
            session.OnBackground();
        };
        Refresh();
    }

    INoteSurface CreateSurface()
    {
#if JITNOTE_WEBVIEW2
        var editor = Path.Combine(AppContext.BaseDirectory, "editor", "index.html");
        if (OperatingSystem.IsWindows() && File.Exists(editor))
            return new WebNoteSurface(session, Path.GetDirectoryName(editor)!);
#endif
        return new TextNoteSurface();
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        if (Viewer.IsVisible && !Scrim.IsVisible && Viewer.HandleKey(e))
        {
            e.Handled = true;
            return;
        }
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control)) return;
        int? code = e.Key switch
        {
            Key.E => 0x45,
            Key.N => 0x4E,
            Key.R => 0x52,
            Key.OemComma => 0xBC,
            _ => null,
        };
        if (code == null) return;
        e.Handled = true;
        DispatchShortcut(code.Value, e.KeyModifiers.HasFlag(KeyModifiers.Shift));
    }

    void DispatchShortcut(int key, bool shift)
    {
        if (Scrim.IsVisible && key != 0xBC) return;
        switch (key)
        {
            case 0x4E when shift:
                AskName("新建文件夹", "文件夹名称", name => session.NewFolder(name));
                break;
            case 0x4E:
                AskName("新建笔记", "笔记名称", name => session.NewNote(name));
                break;
            case 0x52:
                _ = RunSync();
                break;
            case 0x45:
                ToggleMode();
                break;
            case 0xBC:
                ShowSettings();
                break;
        }
    }

    void ToggleMode()
    {
        // A picture has no modes, and the note under one would change unseen.
        if (Viewer.IsVisible) return;
        preview = !preview;
        ShowOpen();
    }

    void Refresh()
    {
        filling = true;
        var notebook = session.Current;
        NotebookPicker.ItemsSource = session.State.Notebooks;
        NotebookPicker.SelectedItem = notebook;
        UnsyncedLabel.IsVisible = session.Unsynced;
        StatusLabel.Text = session.Status ?? notebook?.LastSyncError ?? "";
        SyncButton.Content = session.Syncing ? "正在同步" : "同步";
        surface.SetBusy(session.Syncing);
        session.RefreshTree();
        Tree.Children.Clear();
        if (notebook == null)
        {
            Tree.Children.Add(new TextBlock
            {
                Text = session.State.Accounts.Count == 0 ? "先连接一个云端账号。" : "还没有笔记本。",
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else if (session.Missing(notebook))
        {
            Tree.Children.Add(Act("找不到「" + notebook.Name + "」的文件夹", ShowMissing));
        }
        else
        {
            foreach (var row in session.Rows) Tree.Children.Add(RowButton(row));
        }
        ShowOpen();
        filling = false;
        if (session.Pending.Count > 0 && !Scrim.IsVisible) ShowConflicts();
        else if (session.State.Accounts.Count == 0 && !Scrim.IsVisible) ShowConnect(true);
    }

    Button RowButton(FileTree.Row row)
    {
        var mark = row.Entry.IsFolder ? (session.Expanded.Contains(row.Entry.Path) ? "▾ " : "▸ ") : "";
        var button = new Button
        {
            Content = mark + row.Entry.Name,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Margin = new Avalonia.Thickness(row.Depth * 14, 0, 0, 0),
            Background = session.OpenPath == row.Entry.Path ? new SolidColorBrush(Color.Parse("#E6E6E6")) : Brushes.Transparent,
        };
        button.Click += (_, _) =>
        {
            if (row.Entry.IsFolder) { session.ToggleFolder(row.Entry.Path); return; }
            // Before opening: picking the note a picture is covering has to uncover it, and its path does not change.
            coverImage = null;
            session.OpenNote(row.Entry.Path);
        };
        return button;
    }

    void ShowOpen()
    {
        var path = session.OpenPath;
        if (path != shownPath)
        {
            shownPath = path;
            preview = session.ViewFor(path) == ViewMode.PREVIEW;
            coverImage = null;
        }
        NoteTitle.Text = path == null ? "" : Path.GetFileName(path);
        ModeButton.Content = preview ? "编辑" : "预览";
        ModeButton.IsVisible = path == null || !NoteAssets.IsImage(path);
        if (session.Syncing)
        {
            HideViewer();
            surface.ShowMessage("正在同步");
            return;
        }
        if (path == null || session.Current == null)
        {
            HideViewer();
            surface.ShowMessage(session.Current == null ? "添加一个笔记本之后，笔记会显示在这里。" : "打开左边的一篇笔记");
            return;
        }
        if (coverImage != null)
        {
            // The buttons above act on the open note, which is not what is on screen now.
            ShowViewer(coverImage, covering: true);
            return;
        }
        if (NoteAssets.IsImage(path))
        {
            // Opened from the tree, this is the open file: rename, delete and history apply to it, as with any other.
            shownText = null;
            ShowViewer(path, covering: false);
            return;
        }
        HideViewer();
        if (session.OpenText == null)
        {
            shownText = null;
            surface.ShowMessage("这个文件只在列表里显示");
            return;
        }
        // Reloading on every refresh would put the cursor back at the start while the user is typing.
        if (path == shownPath && preview == shownPreview && session.OpenText == shownText && surface.CurrentText == session.OpenText)
            return;
        shownText = session.OpenText;
        shownPreview = preview;
        surface.ShowText(session.OpenText, preview);
    }

    /// <summary>
    /// The editor is hidden, not removed. It is a native window, so nothing can be drawn over it,
    /// and removing it would destroy the page along with the note's cursor and scroll position.
    /// </summary>
    void ShowViewer(string path, bool covering)
    {
        var root = session.FolderOf(session.Current!);
        // A path that leaves the notebook shows as "cannot open": the viewer gets a name no file has.
        var full = EditorServer.Safe(root, path) ?? Path.Combine(root, ".missing");
        Viewer.Show(full, canGoBack: covering, showName: covering);
        NoteBar.IsVisible = !covering;
        Viewer.IsVisible = true;
        EditorHost.IsVisible = false;
    }

    void HideViewer()
    {
        NoteBar.IsVisible = true;
        if (!Viewer.IsVisible) return;
        Viewer.IsVisible = false;
        Viewer.Clear();
        EditorHost.IsVisible = true;
    }

    void OpenCover(string path)
    {
        coverImage = path;
        ShowOpen();
        // The hidden editor must not keep the keyboard, or typing would still edit the note unseen.
        surface.ReleaseKeyboard();
    }

    void CloseCover()
    {
        coverImage = null;
        ShowOpen();
        // After the layout pass that shows the editor again: a hidden native window cannot take focus.
        Dispatcher.UIThread.Post(surface.TakeKeyboard, DispatcherPriority.Background);
    }

    async Task RunSync()
    {
        if (session.Current == null || session.Syncing) return;
        try { await session.SyncCurrent(); }
        catch (Exception error) { StatusLabel.Text = error.Message; }
        Refresh();
    }

    void AskName(string title, string watermark, Action<string> apply)
    {
        var box = new TextBox { Watermark = watermark };
        var error = new TextBlock { Foreground = Brushes.Firebrick };
        OpenDialog(
            new TextBlock { Text = title, FontSize = 18 },
            box,
            error,
            Buttons(
                ("取消", () => CloseDialog()),
                ("确定", () =>
                {
                    try { apply(box.Text ?? ""); CloseDialog(); }
                    catch (Exception exception) { error.Text = exception.Message; }
                })));
    }

    async Task ConfirmDelete()
    {
        var path = session.OpenPath;
        if (path == null) return;
        OpenDialog(
            new TextBlock { Text = "删除「" + Path.GetFileName(path) + "」？", FontSize = 18, TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = "文件夹里的笔记会一起删除。同步后其他设备上也会删除。误删了也不用怕，历史版本里还能找回。", TextWrapping = TextWrapping.Wrap },
            Buttons(("取消", () => CloseDialog()), ("删除", () => { CloseDialog(); _ = session.DeleteItem(path); })));
        await Task.CompletedTask;
    }

    void ShowConnect(bool first)
    {
        var provider = Provider.GITEE;
        var token = new TextBox { Watermark = "粘贴令牌", PasswordChar = '•' };
        var username = new TextBox { Watermark = "用户名", IsVisible = false };
        var email = new TextBox { Watermark = "邮箱（可不填）", IsVisible = false };
        var help = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = GiteeHelp() };
        var error = new TextBlock { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap };
        var picker = new ComboBox { ItemsSource = new[] { "Gitee", "GitHub", "其他" }, SelectedIndex = 0 };
        picker.SelectionChanged += (_, _) =>
        {
            provider = picker.SelectedIndex switch { 1 => Provider.GITHUB, 2 => Provider.OTHER, _ => Provider.GITEE };
            username.IsVisible = provider == Provider.OTHER;
            email.IsVisible = provider == Provider.OTHER;
            token.Watermark = provider == Provider.OTHER ? "密码或访问令牌" : "粘贴令牌";
            help.Text = provider switch
            {
                Provider.GITHUB => "GitHub 在国内有时连接不稳定。打开 github.com 的令牌页面，勾上需要的权限，再把生成的字符粘贴到下面。",
                Provider.OTHER => "适合自己搭建的服务。填写登录用户名，以及密码或访问令牌。这种方式只能下载已经存在的笔记本，不能在这里新建。",
                _ => GiteeHelp(),
            };
        };
        OpenDialog(
            new TextBlock { Text = "连接云端账号", FontSize = 18 },
            picker,
            help,
            username,
            email,
            token,
            new TextBlock { Text = "令牌只保存在这台电脑上，不会发给任何第三方。", Opacity = 0.7, TextWrapping = TextWrapping.Wrap },
            error,
            Buttons(
                (first ? "退出" : "以后再说", () => { if (first) Close(); else CloseDialog(); }),
                ("连接", () => _ = Connect())));

        async Task Connect()
        {
            try
            {
                await session.Connect(provider, token.Text ?? "", username.Text, email.Text);
                CloseDialog();
            }
            catch (Exception exception) { error.Text = "连接失败：" + exception.Message; }
        }
    }

    static string GiteeHelp() =>
        "Gitee（码云）国内访问快，推荐。在 gitee.com 注册后，打开个人设置里的私人令牌页面，提交后把那一长串字符粘贴到下面。";

    void ShowAddNotebook()
    {
        if (session.State.Accounts.Count == 0) { ShowConnect(false); return; }
        var account = session.AccountOf(session.Current ?? session.State.Notebooks.FirstOrDefault() ?? new Notebook())
            ?? session.State.Accounts[0];
        var accounts = new ComboBox { ItemsSource = session.State.Accounts, SelectedItem = account };
        var mode = new ComboBox { ItemsSource = new[] { "新建", "用已有的" }, SelectedIndex = 0 };
        var name = new TextBox { Watermark = "笔记本名称" };
        var folderBox = new TextBox { IsReadOnly = true, Text = NotebookFolders.DefaultFolder("笔记本") };
        string? picked = null;
        var warning = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#B86E00")), TextWrapping = TextWrapping.Wrap };
        var error = new TextBlock { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap };
        var url = new TextBox { Watermark = "https://gitee.com/…", IsVisible = false };
        var list = new StackPanel { Spacing = 4, IsVisible = false };
        void RefreshFolder()
        {
            var label = name.Text?.Trim();
            if (string.IsNullOrEmpty(label)) label = url.Text == null ? "笔记本" : Session.RepoName(RepoUrls.ToCloneUrl(url.Text));
            folderBox.Text = picked ?? NotebookFolders.DefaultFolder(string.IsNullOrEmpty(label) ? "笔记本" : label);
            warning.Text = NotebookFolders.SyncWarning(folderBox.Text) ?? "";
        }
        name.TextChanged += (_, _) => RefreshFolder();
        url.TextChanged += (_, _) => RefreshFolder();
        mode.SelectionChanged += async (_, _) =>
        {
            var existing = mode.SelectedIndex == 1;
            url.IsVisible = existing && account.Provider == Provider.OTHER;
            list.IsVisible = existing && account.Provider != Provider.OTHER;
            name.Watermark = existing ? "在这台电脑上叫什么（可不填）" : "笔记本名称";
            if (existing && account.Provider != Provider.OTHER) await FillRepos();
        };
        accounts.SelectionChanged += (_, _) =>
        {
            if (accounts.SelectedItem is Account chosen) account = chosen;
        };
        OpenDialog(
            new TextBlock { Text = "添加笔记本", FontSize = 18 },
            accounts,
            mode,
            name,
            url,
            list,
            new TextBlock { Text = "保存位置", Opacity = 0.7 },
            folderBox,
            new TextBlock { Text = "创建后不能更改位置。", Opacity = 0.7 },
            warning,
            error,
            Buttons(
                ("用默认位置", () => { picked = null; RefreshFolder(); }),
                ("更改…", () => _ = PickFolder()),
                ("取消", () => CloseDialog()),
                ("开始", () => _ = Start())));
        RefreshFolder();

        async Task PickFolder()
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false, Title = "选择空文件夹" });
            if (folders.Count == 0) return;
            picked = folders[0].Path.LocalPath;
            RefreshFolder();
            var problem = NotebookFolders.Problem(picked, session.State.Notebooks.Select(session.FolderOf).ToList());
            error.Text = problem ?? "";
        }

        async Task FillRepos()
        {
            list.Children.Clear();
            list.Children.Add(new TextBlock { Text = "正在读取账号里的内容…" });
            try
            {
                var repos = await session.ListRemote(account);
                list.Children.Clear();
                var query = new TextBox { Watermark = repos.Count > 6 ? "搜索" : "" };
                if (repos.Count > 6) list.Children.Add(query);
                var host = new StackPanel { Spacing = 4 };
                list.Children.Add(host);
                void Paint()
                {
                    host.Children.Clear();
                    var needle = (query.Text ?? "").Trim();
                    foreach (var item in repos)
                    {
                        if (needle.Length > 0 && !item.Repo.DisplayName.Contains(needle, StringComparison.OrdinalIgnoreCase)
                            && !item.Repo.Path.Contains(needle, StringComparison.OrdinalIgnoreCase)) continue;
                        var caption = item.Repo.DisplayName + (item.IsLocal ? "（已在这台电脑上）" : "");
                        host.Children.Add(Act(caption, () => ConfirmImport(item.Repo)));
                    }
                }
                query.TextChanged += (_, _) => Paint();
                Paint();
                list.Children.Add(Act("列表里没有？手动填写网址", () => { url.IsVisible = true; }));
            }
            catch (Exception exception)
            {
                list.Children.Clear();
                list.Children.Add(new TextBlock { Text = exception.Message, Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap });
            }
        }

        void ConfirmImport(RemoteRepo repo)
        {
            var lines = new List<Control>
            {
                new TextBlock { Text = "把「" + repo.DisplayName + "」变成笔记本", FontSize = 18, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = "里面原有的文件都会原样保留。", TextWrapping = TextWrapping.Wrap },
            };
            if (!repo.IsPrivate)
                lines.Add(new TextBlock { Text = "注意：这个仓库是公开的，所有人都能看到里面的笔记。", Foreground = new SolidColorBrush(Color.Parse("#B86E00")), TextWrapping = TextWrapping.Wrap });
            if (repo.SizeKb is > 50 * 1024)
                lines.Add(new TextBlock { Text = "这个仓库比较大（约 " + (repo.SizeKb.Value / 1024) + " MB），第一次下载会花一些时间。", TextWrapping = TextWrapping.Wrap });
            lines.Add(Buttons(("换一个", () => ShowAddNotebook()), ("开始下载", () => _ = RunImport(repo.CloneUrl, name.Text ?? repo.DisplayName))));
            OpenDialog(lines.ToArray());
        }

        async Task Start()
        {
            if (accounts.SelectedItem is Account chosen) account = chosen;
            try
            {
                if (mode.SelectedIndex == 0)
                {
                    var title = (name.Text ?? "").Trim();
                    if (title.Length == 0) throw new SyncException(SyncErrorKind.Other, "请填写笔记本名称");
                    var slug = RepoNames.FromName(title);
                    if (!RepoNames.IsValid(slug) && !slug.StartsWith("notes-", StringComparison.Ordinal))
                        throw new SyncException(SyncErrorKind.Other, "这个名称不合适，请换一个");
                    var progress = new Progress<string>(text => error.Text = text);
                    await session.CreateNotebook(account, title, slug, picked, progress);
                }
                else if (url.IsVisible)
                {
                    await RunImport(RepoUrls.ToCloneUrl(url.Text ?? ""), name.Text ?? "");
                    return;
                }
                else return;
                CloseDialog();
            }
            catch (Exception exception) { error.Text = exception.Message; }
        }

        async Task RunImport(string cloneUrl, string display)
        {
            try
            {
                var progress = new Progress<string>(text => StatusLabel.Text = text);
                await session.ImportNotebook(account, cloneUrl, display, picked, progress);
                CloseDialog();
            }
            catch (Exception exception) { error.Text = exception.Message; OpenDialog(new TextBlock { Text = exception.Message, TextWrapping = TextWrapping.Wrap }, Buttons(("关闭", () => CloseDialog()))); }
        }
    }

    void ShowSettings()
    {
        var hidden = new CheckBox { Content = "显示隐藏文件（以 . 开头的文件。.git 始终不显示）", IsChecked = session.State.ShowHiddenFiles };
        var autoSync = new CheckBox { Content = "启动时自动同步", IsChecked = session.State.SyncOnLaunch };
        var sort = new ComboBox
        {
            ItemsSource = new[] { "按名称", "按名称（倒序）", "按修改时间", "按修改时间（从早到晚）" },
            SelectedIndex = session.State.FileSort switch
            {
                NoteSort.TITLE_DESC => 1,
                NoteSort.MODIFIED_DESC => 2,
                NoteSort.MODIFIED_ASC => 3,
                _ => 0,
            },
        };
        var view = new ComboBox { ItemsSource = new[] { "编辑", "预览" }, SelectedIndex = session.State.DefaultViewMode == ViewMode.PREVIEW ? 1 : 0 };
        var rows = new List<Control>
        {
            new TextBlock { Text = "设置", FontSize = 18 },
            hidden,
            autoSync,
            new TextBlock { Text = "打开程序，或离开超过一分钟后再回来，自动同步当前笔记本。没有变化时不提示。", Opacity = 0.7, TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = "新建的笔记和纯文本文件总是编辑。" , Opacity = 0.7, TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = "文件怎么排" },
            sort,
            new TextBlock { Text = "打开笔记时" },
            view,
        };
        foreach (var account in session.State.Accounts)
        {
            rows.Add(new TextBlock { Text = account.Provider.Label() + " · " + account.Login });
            rows.Add(Act("断开 " + account.Login, () => ConfirmDisconnect(account)));
        }
        rows.Add(Act("检查更新", () => _ = OfferUpdate(true)));
        if (session.Current != null)
        {
            var current = session.Current;
            rows.Add(Act("在文件管理器中打开", () => Session.OpenFolder(session.FolderOf(current))));
            rows.Add(Act("复制路径", async () => await CopyText(session.FolderOf(current))));
            rows.Add(Act("从这台电脑移除", () => ConfirmRemove(current)));
        }
        rows.Add(Buttons(("关闭", () =>
        {
            session.SetHidden(hidden.IsChecked == true);
            session.SetSyncOnLaunch(autoSync.IsChecked == true);
            session.SetSort(sort.SelectedIndex switch
            {
                1 => NoteSort.TITLE_DESC,
                2 => NoteSort.MODIFIED_DESC,
                3 => NoteSort.MODIFIED_ASC,
                _ => NoteSort.TITLE_ASC,
            });
            session.SetDefaultView(view.SelectedIndex == 1 ? ViewMode.PREVIEW : ViewMode.EDIT);
            CloseDialog();
        })));
        OpenDialog(rows.ToArray());
    }

    void ConfirmDisconnect(Account account)
    {
        OpenDialog(
            new TextBlock { Text = "断开 " + account.Login + "？", FontSize = 18 },
            new TextBlock { Text = "这台电脑会删除保存的授权，云端账号和笔记不受影响。", TextWrapping = TextWrapping.Wrap },
            Buttons(("取消", ShowSettings), ("断开", () => { session.Disconnect(account); CloseDialog(); })));
    }

    void ConfirmRemove(Notebook notebook)
    {
        var keeps = notebook.FolderChosen;
        OpenDialog(
            new TextBlock { Text = "从这台电脑移除「" + notebook.Name + "」？", FontSize = 18, TextWrapping = TextWrapping.Wrap },
            new TextBlock
            {
                Text = keeps ? "文件夹是你自己选的，里面的文件会原样留在原地。云端不受影响。" : "只会删除这台电脑上的副本。云端不受影响。",
                TextWrapping = TextWrapping.Wrap,
            },
            Buttons(("取消", ShowSettings), ("移除", () => { session.RemoveLocal(notebook); CloseDialog(); })));
    }

    void ShowConflicts()
    {
        var rows = new List<Control>
        {
            new TextBlock { Text = "同一处改动了两边", FontSize = 18 },
            new TextBlock { Text = "请选择每一篇以哪边为准。没选中的那一版不会丢，仍然留在历史版本里。", TextWrapping = TextWrapping.Wrap },
        };
        foreach (var conflict in session.Pending)
        {
            rows.Add(new TextBlock { Text = conflict.Path, FontWeight = FontWeight.SemiBold });
            rows.Add(new TextBlock { Text = "这台电脑", Opacity = 0.7 });
            rows.Add(Preview(conflict.Local));
            rows.Add(new TextBlock { Text = "云端", Opacity = 0.7 });
            rows.Add(Preview(conflict.Cloud));
            var local = new RadioButton { Content = "用这台电脑", GroupName = conflict.Path, IsChecked = session.Choices.TryGetValue(conflict.Path, out var side) && side == Side.LOCAL };
            var remote = new RadioButton { Content = "用云端", GroupName = conflict.Path, IsChecked = session.Choices.TryGetValue(conflict.Path, out side) && side == Side.REMOTE };
            local.IsCheckedChanged += (_, _) => { if (local.IsChecked == true) session.Choices[conflict.Path] = Side.LOCAL; };
            remote.IsCheckedChanged += (_, _) => { if (remote.IsChecked == true) session.Choices[conflict.Path] = Side.REMOTE; };
            rows.Add(local);
            rows.Add(remote);
        }
        rows.Add(Buttons(
            ("取消", () => { session.CancelConflicts(); CloseDialog(); }),
            ("全部用这台电脑", () => _ = Apply(session.Pending.ToDictionary(item => item.Path, _ => Side.LOCAL))),
            ("全部用云端", () => _ = Apply(session.Pending.ToDictionary(item => item.Path, _ => Side.REMOTE))),
            ("就按这样", () => _ = Apply(new Dictionary<string, Side>(session.Choices)))));
        OpenDialog(rows.ToArray());

        async Task Apply(Dictionary<string, Side> choices)
        {
            if (session.Current == null) return;
            if (session.Pending.Any(item => !choices.ContainsKey(item.Path))) return;
            CloseDialog();
            try { await session.Sync(session.Current, choices); }
            catch (Exception error) { StatusLabel.Text = error.Message; }
        }
    }

    static Control Preview(byte[]? content) => new TextBox
    {
        Text = content == null ? "这一边已经删除" : System.Text.Encoding.UTF8.GetString(content),
        IsReadOnly = true,
        AcceptsReturn = true,
        Height = 90,
        TextWrapping = TextWrapping.Wrap,
    };

    void ShowHistory()
    {
        var path = session.OpenPath;
        if (path == null || session.Current == null) return;
        IReadOnlyList<Version> versions;
        try { versions = session.History(path); }
        catch (Exception error)
        {
            OpenDialog(new TextBlock { Text = error.Message }, Buttons(("关闭", CloseDialog)));
            return;
        }
        var rows = new List<Control> { new TextBlock { Text = "「" + Path.GetFileName(path) + "」的历史版本", FontSize = 18, TextWrapping = TextWrapping.Wrap } };
        if (versions.Count == 0) rows.Add(new TextBlock { Text = "还没有历史版本" });
        var preview = new TextBox { IsReadOnly = true, AcceptsReturn = true, Height = 160, TextWrapping = TextWrapping.Wrap };
        string? chosen = null;
        foreach (var version in versions)
        {
            var when = DateTimeOffset.FromUnixTimeMilliseconds(version.Time).LocalDateTime.ToString("yyyy-MM-dd HH:mm");
            rows.Add(Act(when + "  " + version.Message, () =>
            {
                chosen = version.Commit;
                preview.Text = session.ReadVersion(version.Commit, path) ?? "这一版里没有这个文件";
            }));
        }
        rows.Add(preview);
        rows.Add(new TextBlock { Text = "当前内容会被这个版本替换。不用担心，当前内容也会留在历史版本里。", TextWrapping = TextWrapping.Wrap });
        rows.Add(Buttons(("关闭", CloseDialog), ("恢复这一版", () =>
        {
            if (chosen == null) return;
            try { session.Restore(path, chosen); CloseDialog(); }
            catch (Exception error) { preview.Text = error.Message; }
        })));
        OpenDialog(rows.ToArray());
    }

    void ShowMissing()
    {
        var notebook = session.Current;
        if (notebook == null) return;
        var error = new TextBlock { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap };
        OpenDialog(
            new TextBlock { Text = "找不到「" + notebook.Name + "」的文件夹", FontSize = 18, TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = session.FolderOf(notebook), TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = "可能被移动或删除了，或者放它的硬盘没有插上。云端的笔记没有受影响。", TextWrapping = TextWrapping.Wrap },
            error,
            Buttons(
                ("重新检查", () => { if (!session.Missing(notebook)) CloseDialog(); else error.Text = "还是找不到"; }),
                ("重新选择文件夹…", () => _ = Pick()),
                ("重新下载到原位置…", () => ConfirmRedownload(notebook))));

        async Task Pick()
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false, Title = "重新选择文件夹" });
            if (folders.Count == 0) return;
            try
            {
                session.Relocate(notebook, folders[0].Path.LocalPath);
                CloseDialog();
            }
            catch (Exception exception) { error.Text = exception.Message; }
        }
    }

    void ConfirmRedownload(Notebook notebook)
    {
        OpenDialog(
            new TextBlock { Text = "重新下载到原位置？", FontSize = 18 },
            new TextBlock { Text = "还没同步的本地修改会丢掉。云端的内容会重新下载到原来的文件夹。", TextWrapping = TextWrapping.Wrap },
            Buttons(("取消", ShowMissing), ("重新下载", () => _ = Run())));

        async Task Run()
        {
            try
            {
                await session.Redownload(notebook, new Progress<string>(text => StatusLabel.Text = text));
                CloseDialog();
            }
            catch (Exception error)
            {
                OpenDialog(new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap }, Buttons(("关闭", ShowMissing)));
            }
        }
    }

    async Task OfferUpdate(bool manual)
    {
        var (release, error) = await session.CheckUpdate(manual);
        if (release == null)
        {
            if (manual && error != null)
                OpenDialog(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap }, Buttons(("关闭", CloseDialog)));
            return;
        }
        var progress = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var cancel = new CancellationTokenSource();
        OpenDialog(
            new TextBlock { Text = "有新版本 " + release.Version, FontSize = 18 },
            new TextBlock { Text = release.Notes, TextWrapping = TextWrapping.Wrap },
            new TextBlock { Text = "下载完成后会打开它所在的位置。请先退出记特，再用新的文件替换现在的。正在运行的程序不会被覆盖。", TextWrapping = TextWrapping.Wrap },
            progress,
            Buttons(
                ("以后再说", () => { cancel.Cancel(); CloseDialog(); }),
                ("下载", () => _ = Download())));

        async Task Download()
        {
            try
            {
                var reporter = new Progress<long>(bytes => progress.Text = "已下载 " + (bytes / 1024) + " KB");
                var package = await session.DownloadUpdate(release, reporter, cancel.Token);
                Session.Reveal(package);
                progress.Text = package.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                    ? "下载好了。退出记特后，用新的 Jitnote.exe 替换现在的。"
                    : "下载好了。退出记特后，用新的文件替换现在的。";
            }
            catch (OperationCanceledException) { /* the user closed the dialog */ }
            catch { progress.Text = "下载没有完成，可能是网络不稳定。"; }
        }
    }

    async Task CopyText(string text)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard != null) await clipboard.SetTextAsync(text);
    }

    void OpenDialog(params Control[] rows)
    {
        Dialog.Children.Clear();
        foreach (var row in rows) Dialog.Children.Add(row);
        Scrim.IsVisible = true;
    }

    void CloseDialog() => Scrim.IsVisible = false;

    static Button Act(string text, Action click)
    {
        var button = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => click();
        return button;
    }

    static StackPanel Buttons(params (string Text, Action Click)[] actions)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var action in actions) panel.Children.Add(Act(action.Text, action.Click));
        return panel;
    }
}
