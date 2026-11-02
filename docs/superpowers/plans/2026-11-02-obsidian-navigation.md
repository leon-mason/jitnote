# 向 Obsidian 靠齐的导航和打开方式：实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把两端的导航改成文件树（Mac 两栏，安卓首页全屏文件树），并加上默认编辑/预览设置和切换。

**Architecture:** 展开、高亮、新建位置的规则写成两端各一份的纯函数 `FileTree`（Kotlin 和 Swift 同名同义），界面只负责调用，这样规则能单测。编辑/预览通过共用编辑器新增的 `setReadonly` 切换。两端各自分「数据层 → 文件树界面 → 预览」三步，每一步结束都能构建和运行。

**Tech Stack:** Kotlin + Compose、Swift + SwiftUI（用 `swiftc` 构建，无 XCTest）、Milkdown Crepe + Vite + Vitest。

**Spec:** `docs/superpowers/specs/2026-11-02-obsidian-navigation-design.md`（执行前必读，文案和交互规则以它为准）

## Global Constraints

- 所有工作在分支 `obsidian-navigation` 上，不直接提交到 `main`。设计文档和本计划在第一个任务里一起提交。
- 提交信息用英文，风格同现有历史（祈使句，如 "Show symlinked notes under their own name"），结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 注释用英文，界面文案用中文，密度和现有代码一致。
- 默认排序：名称 A→Z（`fileSort` 默认 `TITLE_ASC`）。默认模式：编辑（`defaultViewMode` 默认 `EDIT`）。
- 打开或预览笔记绝不写文件：不动 `NoteSaver` 的「`edited` 才保存」规则。
- 冲突入口在任何时候都不能消失。
- 不新增第三方依赖。

## Review Focus

- 高亮的文件或文件夹已被同步删除，或因关闭「显示隐藏文件」不再显示：新建要落到根目录而不是报错。测试在 Task 2、Task 5（`currentFolderFallsBackToRootWhenMissing`）。
- 名字有相同前缀的文件夹（`会议` 和 `会议记录`）：重命名或删除 `会议` 不能影响 `会议记录`。测试在 Task 2、Task 5（`renameDoesNotTouchSimilarNames`）。
- 升级时读到带 `noteSort` 的旧状态文件：账号和笔记本必须都在。安卓的 `StateStore.load` 解析失败会退回空状态，等于丢掉所有账号。测试在 Task 2、Task 5（`oldStateFileKeepsAccountsAndNotebooks`）。
- 刚打完字 400ms 内切到预览：刚打的字仍要保存。测试在 Task 1（`editJustBeforePreviewIsStillSaved`）。
- 展开记录里有已不存在的路径（同步后常见）：文件树正常显示，不崩溃。测试在 Task 2、Task 5（`visibleRowsIgnoreStaleExpandedPaths`）。

---

### Task 1: 编辑器支持中途切换只读

**Files:**
- Modify: `editor/src/main.js`（接口说明、`load`、`window.JitnoteEditor`）
- Test: `editor/test/readonly.test.js`（新建，环境搭建照抄 `roundtrip.test.js` 的 `beforeAll`，`onChange` 记录到数组）
- Modify: `docs/design.md:82`（接口说明）
- Rebuild: `android/app/src/main/assets/editor/`

**Interfaces:**
- Produces: `window.JitnoteEditor.setReadonly(readonly: boolean): void`。后面两端都用它。

- [ ] **Step 1: 建分支并提交设计文档和计划**

```bash
git switch -c obsidian-navigation
git add docs/superpowers/specs/2026-11-02-obsidian-navigation-design.md docs/superpowers/plans/2026-11-02-obsidian-navigation.md
git commit -m "Add the design and plan for Obsidian-style navigation"
```

- [ ] **Step 2: 写失败的测试**

```js
it('setReadonlyTogglesEditingAndToolbar', async () => {
  await editor.load('正文\n', {})
  editor.setReadonly(true)
  expect(document.querySelector('#toolbar').hidden).toBe(true)
  expect(document.body.classList.contains('with-toolbar')).toBe(false)
  expect(document.querySelector('.ProseMirror').getAttribute('contenteditable')).toBe('false')
  editor.setReadonly(false)
  expect(document.querySelector('#toolbar').hidden).toBe(false)
  expect(document.body.classList.contains('with-toolbar')).toBe(true)
})

it('setReadonlyDuringLoadWins', async () => {
  const loading = editor.load('正文\n', { readonly: false })
  editor.setReadonly(true)
  await loading
  expect(document.querySelector('#toolbar').hidden).toBe(true)
})

it('editJustBeforePreviewIsStillSaved', async () => {
  await editor.load('正文\n', {})
  changes.length = 0
  document.querySelector('#toolbar button').click() // 第一个按钮「标题」会改动文档
  editor.setReadonly(true)
  await new Promise((resolve) => setTimeout(resolve, 1000))
  expect(changes.at(-1)).toContain('## 正文')
})
```

如果 jsdom 里点工具栏改不动文档，把第三个测试去掉，改为在 Task 4、Task 7 的实机验证里覆盖，并在任务报告里说明。

- [ ] **Step 3: 确认失败**

Run: `cd editor && npm test`
Expected: FAIL，`editor.setReadonly is not a function`

- [ ] **Step 4: 实现 `setReadonly`**

模块级变量 `wantReadonly`：`load` 开头设为 `Boolean(options.readonly)`，`crepe.create()` 之后应用当前值（取代现有三行）；`setReadonly` 更新它，并在 `crepe` 已创建完成时立刻应用。切到只读时对 `document.activeElement` 调 `blur()`。不碰 `changeTimer`。把 `setReadonly` 加进 `window.JitnoteEditor` 和文件开头的接口说明。

- [ ] **Step 5: 确认通过**

Run: `cd editor && npm test`
Expected: PASS，`roundtrip.test.js` 也通过

- [ ] **Step 6: 重新构建并提交**

Run: `cd editor && npm run build`
Expected: `android/app/src/main/assets/editor/` 下只有一个 `index-*.js`（有旧文件残留就删掉）

```bash
git add editor docs/design.md android/app/src/main/assets/editor
git commit -m "Let the editor switch between editing and read-only without reloading"
```

---

### Task 2: 安卓数据层

**Files:**
- Create: `android/app/src/main/java/io/github/leonmason/jitnote/data/FileTree.kt`
- Modify: `data/NoteIndex.kt`、`data/Models.kt:48`、`data/Notebooks.kt:182`
- Test: `android/app/src/test/java/io/github/leonmason/jitnote/data/NoteIndexTest.kt`、`FileTreeTest.kt`（新建）、`StateStoreTest.kt`（新建）

（下文路径省略 `android/app/src/main/java/io/github/leonmason/jitnote/`。）

**Interfaces:**
- Produces:
  - `NoteIndex.Entry` 新增 `modified: Long`
  - `NoteIndex.tree(root: File, sort: NoteSort = NoteSort.TITLE_ASC, showHidden: Boolean = false): List<Entry>`
  - `AppState` 新增 `fileSort: NoteSort = TITLE_ASC`、`expandedFolders: Map<String, Set<String>> = emptyMap()`（键是笔记本 id）、`defaultViewMode: ViewMode = ViewMode.EDIT`；删除 `noteSort`
  - `@Serializable enum class ViewMode { EDIT, PREVIEW }`（在 `Models.kt`）
  - `Notebooks.setFileSort(sort: NoteSort)`（取代 `setSort`）、`setExpandedFolders(notebookId: String, paths: Set<String>)`、`setDefaultViewMode(mode: ViewMode)`；`deleteLocal` 同时清掉该笔记本的展开记录
  - `object FileTree`：
    - `data class Row(val entry: NoteIndex.Entry, val depth: Int)`
    - `visibleRows(tree: List<Entry>, expanded: Set<String>): List<Row>`
    - `find(tree: List<Entry>, path: String): Entry?`
    - `parent(path: String): String`（顶层返回 `""`）
    - `ancestors(path: String): Set<String>`（`"a/b/c.md"` → `{"a", "a/b"}`）
    - `currentFolder(tree: List<Entry>, highlighted: String): String`
    - `moved(path: String, old: String, new: String): String`（`path` 是 `old` 或在它里面时替换前缀，否则原样返回）
    - `renamed(expanded: Set<String>, old: String, new: String): Set<String>`
    - `removed(expanded: Set<String>, path: String): Set<String>`

`NoteIndex.notes`、`Note`、`preview` 这一步先留着（界面还在用），Task 3 删。`NoteSort` 的 label 把「标题」改成「名称」。

- [ ] **Step 1: 写失败的测试**

`NoteIndexTest`：

```kotlin
@Test fun treeSortsByNameBothWays() {
    write("b.md"); write("a.md"); write("乙/x.md"); write("甲/x.md")
    assertEquals(listOf("甲", "乙", "a.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.TITLE_ASC).map { it.name })
    assertEquals(listOf("乙", "甲", "b.md", "a.md"), NoteIndex.tree(tmp.root, NoteSort.TITLE_DESC).map { it.name })
}

@Test fun treeSortsFilesByMinuteAndKeepsFoldersByName() {
    write("a.md", modified = 60_000_000); write("b.md", modified = 180_000_000); write("c.md", modified = 120_000_000)
    write("乙/x.md"); write("甲/x.md")
    assertEquals(listOf("甲", "乙", "b.md", "c.md", "a.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_DESC).map { it.name })
    assertEquals(listOf("甲", "乙", "a.md", "c.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_ASC).map { it.name })
}

@Test fun treeBreaksTiesInTheSameMinuteByName() {
    write("b.md", modified = 60_000_000); write("a.md", modified = 60_030_000)
    assertEquals(listOf("a.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_DESC).map { it.name })
}
```

`FileTreeTest`（用手写的 `Entry` 组树：`会议/2026/周会.md`、`会议记录/`、`a.md`）：

```kotlin
@Test fun visibleRowsOnlyShowOpenFolders() { /* expanded = {"会议"} → 名字 ["会议","2026","会议记录","a.md"]，depth [0,1,0,0] */ }
@Test fun visibleRowsIgnoreStaleExpandedPaths() { /* expanded = {"不存在/的"} → 名字 ["会议","会议记录","a.md"] */ }
@Test fun currentFolderOfAFolderIsItself() { assertEquals("会议/2026", FileTree.currentFolder(tree, "会议/2026")) }
@Test fun currentFolderOfAFileIsItsParent() { assertEquals("会议/2026", FileTree.currentFolder(tree, "会议/2026/周会.md")); assertEquals("", FileTree.currentFolder(tree, "a.md")) }
@Test fun currentFolderFallsBackToRootWhenMissing() { assertEquals("", FileTree.currentFolder(tree, "已删除/x.md")); assertEquals("", FileTree.currentFolder(tree, "")) }
@Test fun parentAndAncestors() { assertEquals("会议", FileTree.parent("会议/2026")); assertEquals("", FileTree.parent("会议")); assertEquals(setOf("会议", "会议/2026"), FileTree.ancestors("会议/2026/周会.md")) }
@Test fun renameMovesTheFolderAndWhatIsInside() { assertEquals(setOf("工作", "工作/2026", "b"), FileTree.renamed(setOf("会议", "会议/2026", "b"), "会议", "工作")) }
@Test fun renameDoesNotTouchSimilarNames() { assertEquals(setOf("工作", "会议记录"), FileTree.renamed(setOf("会议", "会议记录"), "会议", "工作")); assertEquals("会议记录/x.md", FileTree.moved("会议记录/x.md", "会议", "工作")) }
@Test fun removeDropsTheFolderAndWhatIsInside() { assertEquals(setOf("会议记录"), FileTree.removed(setOf("会议", "会议/2026", "会议记录"), "会议")) }
```

`StateStoreTest`（`StateStore` 接受 `File`，直接写 JSON 文件）：

```kotlin
@Test fun oldStateFileKeepsAccountsAndNotebooks() {
    // JSON 带 "noteSort":"MODIFIED_DESC" 和一个账号、一个笔记本（字段按 Models.kt 填全）
    val state = StateStore(file).state.value
    assertEquals(1, state.accounts.size); assertEquals(1, state.notebooks.size)
    assertEquals(NoteSort.TITLE_ASC, state.fileSort); assertEquals(ViewMode.EDIT, state.defaultViewMode)
}
```

- [ ] **Step 2: 确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: 编译失败，`FileTree`、`fileSort` 未定义

- [ ] **Step 3: 实现上面 Interfaces 列出的内容**

`entries` 的同级排序：文件夹在前。`TITLE_ASC` 全按名称；`TITLE_DESC` 文件夹和文件都反向；`MODIFIED_*` 文件夹按名称 A→Z，文件按 `lastModified / 60_000`，同一分钟按名称。这是沿用 `notes` 现有的比较方式。

`HomeScreen.kt` 里的 `state.noteSort` 和 `notebooks::setSort` 暂时改成 `fileSort` 和 `setFileSort`，保证能编译。

- [ ] **Step 4: 确认通过**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: BUILD SUCCESSFUL

- [ ] **Step 5: 提交**

```bash
git add android/app/src
git commit -m "Add file tree rules and sorted trees on Android"
```

---

### Task 3: 安卓首页改成全屏文件树

**Files:**
- Modify: `ui/HomeScreen.kt`、`ui/Navigation.kt:36-38`、`data/NoteIndex.kt`
- Rename: `ui/FileListDrawer.kt` → `ui/FileTreeList.kt`
- Test: `NoteIndexTest.kt`（删掉 `notes`、`preview` 相关用例，隐藏文件用例只留 `tree` 部分）

**Interfaces:**
- Consumes: Task 2 的 `FileTree`、`NoteIndex.tree`、`Notebooks.setExpandedFolders`、`setFileSort`
- Produces: `Navigator.highlighted: SnapshotStateMap<String, String>`、`Navigator.trees: SnapshotStateMap<String, List<NoteIndex.Entry>>`、`Navigator.treeScroll: MutableMap<String, LazyListState>`（都按笔记本 id）；`Screen.Editor(notebookId, path, startEditing: Boolean = false)`

界面改动没有单元测试，靠构建和 Task 8 的实机验证。

- [ ] **Step 1: 改 `Navigator`**

删 `homeFolder`、`expandedFolders`，加上面三个字段。`Screen.Editor` 加 `startEditing`。

- [ ] **Step 2: 把 `FileListDrawer` 改成 `FileTreeList.kt`**

```kotlin
@Composable fun FileTreeRow(
    row: FileTree.Row, isExpanded: Boolean, isHighlighted: Boolean,
    onClick: () -> Unit, onHistory: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit,
    onNewNoteHere: () -> Unit, onNewFolderHere: () -> Unit,
)
```

去掉 `ModalDrawerSheet`、「全部笔记」和递归。文件夹都显示箭头（只是图标，不再是 `IconButton`），整行响应点击。文件夹的长按菜单加「新建笔记」「新建文件夹」。

- [ ] **Step 3: 重写 `NotesHome`**

去掉 `ModalNavigationDrawer`、☰、`notes`、`total`、`ListHeader` 的「看全部」、`NoteRow`、`BackHandler`。

- `LazyColumn(state = nav.treeScroll.getOrPut(notebook.id) { LazyListState() })`，内容依次是同步状态、`ConflictsCard`、排序和新建文件夹、`items(FileTree.visibleRows(tree, expanded), key = { it.entry.path })`。
- `tree` 取自 `nav.trees[notebook.id]`，加载完写回去，所以返回时不闪空白。
- 点文件夹：收起时展开并高亮；展开时收起并把高亮设成 `FileTree.parent(path)`。
- 点文件：高亮并按现有 `openFile` 打开。
- `val here = FileTree.currentFolder(tree, highlighted)` 取代 `folder`。新建对话框标题：`here` 为空时「新建笔记」，否则「在「${here.substringAfterLast('/')}」里新建笔记」，文件夹同理。长按「新建笔记」「新建文件夹」用该文件夹作为位置。
- 新建后：`setExpandedFolders(展开 + ancestors(新路径))`，高亮新路径；新笔记用 `Screen.Editor(..., startEditing = true)` 打开。
- 重命名：展开记录用 `FileTree.renamed`，高亮用 `FileTree.moved`。删除：展开记录用 `FileTree.removed`；高亮等于被删项或在它里面时设成 `FileTree.parent(被删路径)`。

- [ ] **Step 4: 删除无用代码**

删 `NoteIndex.Note`、`notes`、`preview` 及其私有辅助函数，以及对应的测试。

- [ ] **Step 5: 确认构建和测试通过**

Run: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 6: 提交**

```bash
git add android/app/src
git commit -m "Make the file tree the Android home screen"
```

---

### Task 4: 安卓的编辑/预览

**Files:**
- Modify: `ui/EditorScreen.kt`、`ui/NoteWebView.kt:67-149`、`ui/SettingsScreen.kt`、`ui/Navigation.kt`、`ui/HomeScreen.kt`

**Interfaces:**
- Consumes: Task 1 的 `setReadonly`、Task 2 的 `ViewMode`、`setDefaultViewMode`、Task 3 的 `Screen.Editor.startEditing`
- Produces: `Navigator.editorMode: SnapshotStateMap<Screen.Editor, ViewMode>`，只存用户在当前笔记上切换过的模式

- [ ] **Step 1: `NoteWebView` 的 `readonly` 改成可变**

`onReady` 读 `rememberUpdatedState(readonly)` 的最新值。`AndroidView` 的 `update` 里，值变化时执行 `window.JitnoteEditor && window.JitnoteEditor.setReadonly(...)`；切到只读时用 `InputMethodManager.hideSoftInputFromWindow` 收起键盘。

- [ ] **Step 2: `EditorScreen` 加切换**

```kotlin
val mode = nav.editorMode[screen] ?: if (screen.startEditing) ViewMode.EDIT else state.defaultViewMode
```

顶栏在历史版本按钮左边加切换按钮，只在 `md`、`markdown` 文件上显示；点击写入 `nav.editorMode[screen]`。把 `readonly = mode == ViewMode.PREVIEW` 传给 `RichNoteEditor` → `NoteWebView`。纯文本编辑器不变。

- [ ] **Step 3: 回到首页时清除临时模式**

`NotesHome` 里 `LaunchedEffect(Unit) { nav.editorMode.clear() }`。看历史版本和图片时不经过首页，所以模式会保留。

- [ ] **Step 4: 设置页**

在 `SettingsScreen` 现有条目下加一项：标题「打开笔记时默认为」，说明「新建的笔记和纯文本文件总是编辑。」，用 `SingleChoiceSegmentedButtonRow` 选「编辑」「预览」，绑定 `state.defaultViewMode` 和 `notebooks::setDefaultViewMode`。

- [ ] **Step 5: 确认构建通过**

Run: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 6: 提交**

```bash
git add android/app/src
git commit -m "Add the default view setting and a preview toggle on Android"
```

---

### Task 5: Mac 数据层

**Files:**
- Create: `mac/Sources/Data/FileTree.swift`
- Modify: `mac/Sources/Data/NoteFiles.swift`、`mac/Sources/Data/Models.swift:45-100`、`mac/Sources/Data/Notebooks.swift:43`
- Test: `mac/Tests/DataTests.swift`（新用例；新增 `FileTreeTests`，并在 `mac/Tests/TestRunner.swift:33` 后注册）

**Interfaces:**
- Produces（规则和 Task 2 完全一致，测试名也相同）：
  - `NoteIndex.Entry` 新增 `modified: Int64`；`children` 改成 `[Entry]`（文件和空文件夹为 `[]`，不再用 nil），现有断言 `children == nil` 改成 `children.isEmpty`，`children!` 去掉 `!`
  - `NoteIndex.tree(in root: URL, sort: NoteSort = .titleAsc, showHidden: Bool = false) -> [Entry]`
  - `AppState` 新增 `fileSort: NoteSort = .titleAsc`、`expandedFolders: [String: Set<String>] = [:]`、`defaultViewMode: ViewMode = .edit`，都在 `init(from:)` 里用 `decodeIfPresent` 读；删除 `noteSort`
  - `enum ViewMode: String, Codable { case edit = "EDIT", preview = "PREVIEW" }`
  - `Notebooks.setFileSort(_:)`（取代 `setSort`）、`setExpandedFolders(_ notebookId: String, _ paths: Set<String>)`、`setDefaultViewMode(_:)`；移除笔记本时清掉它的展开记录
  - `enum FileTree`：`struct Row: Identifiable { let entry: NoteIndex.Entry; let depth: Int }`，`visibleRows(_:expanded:)`、`find(_:path:)`、`parent(_:)`、`ancestors(_:)`、`currentFolder(_:highlighted:)`、`moved(_:old:new:)`、`renamed(_:old:new:)`、`removed(_:path:)`

`NoteSort.label` 把「标题」改成「名称」。`notes`、`Note`、`preview` 先留着，Task 6 删。

- [ ] **Step 1: 写失败的测试**

把 Task 2 的测试逐条移植成 `TestCase`，名字和数据都相同（`treeSortsByNameBothWays`、`treeSortsFilesByMinuteAndKeepsFoldersByName`、`treeBreaksTiesInTheSameMinuteByName`，以及 `FileTreeTest` 全部）。旧状态文件的用例直接解码 JSON：

```swift
TestCase("oldStateFileKeepsAccountsAndNotebooks") { _ in
    let json = #"{"accounts":[],"notebooks":[],"currentNotebookId":"x","noteSort":"MODIFIED_DESC","showHiddenFiles":true}"#
    let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
    try expectEqual(state.currentNotebookId, "x")
    try expect(state.showHiddenFiles)
    try expectEqual(state.fileSort, .titleAsc)
    try expectEqual(state.defaultViewMode, .edit)
}
```

账号和笔记本各填一条（字段按 `Models.swift`），断言数量为 1。

- [ ] **Step 2: 确认失败**

Run: `scripts/build-mac.sh --test`
Expected: 编译失败，`FileTree` 未定义

- [ ] **Step 3: 实现上面 Interfaces 列出的内容**

排序规则同 Task 2 Step 3。`MainWindow.swift` 暂时改用 `fileSort`、`setFileSort`；`OutlineGroup` 需要可选的 `children`，这一步临时写成 `children: \.optionalChildren`（`Entry` 上的计算属性，空时返回 nil，Task 6 删）。

- [ ] **Step 4: 确认通过**

Run: `scripts/build-mac.sh --test`，再运行 `scripts/build-mac.sh --debug`
Expected: 测试全部通过，App 能构建

- [ ] **Step 5: 提交**

```bash
git add mac
git commit -m "Add file tree rules and sorted trees on the Mac"
```

---

### Task 6: Mac 改成两栏

**Files:**
- Modify: `mac/Sources/UI/MainWindow.swift`、`mac/Sources/Data/NoteFiles.swift`、`mac/Sources/UI/DebugHooks.swift:12-16`
- Test: `mac/Tests/DataTests.swift`（删 `notes`、`preview` 相关用例，隐藏文件用例只留 `tree` 部分）

**Interfaces:**
- Consumes: Task 5 的 `FileTree`、`NoteIndex.tree`、`setExpandedFolders`、`setFileSort`
- Produces: `NotebookView` 的 `@State highlighted: String`（取代 `folder`）

- [ ] **Step 1: `NavigationSplitView` 改成两栏，重写 `Sidebar`**

删 `NoteList`、`NoteRow`、`notes`、`total`、`folder`。左栏顺序按设计文档。文件树用 `ScrollView` + `LazyVStack` + `ForEach(FileTree.visibleRows(tree, expanded))` 自己画，不用 `List(selection:)`（再次点击选中行不触发回调）也不用 `OutlineGroup`。

- 每行按 `depth` 缩进，文件夹显示箭头，高亮行用圆角的强调色背景。
- 行的 `.onTapGesture` 规则和 Task 3 Step 3 相同。图片、其他文件走现有 `open`。
- 内容区背景的 `.onTapGesture` 把 `highlighted` 设成 `""`。
- 右键菜单保留，文件夹加「新建笔记…」「新建文件夹…」。
- `SyncStatusLine`、冲突按钮、排序菜单从 `NoteList` 原样搬到左栏。

- [ ] **Step 2: 调整 `NotebookView` 的新建、重命名、删除**

- `Prompt` 改成 `.newNote(String)`、`.newFolder(String)`，参数是目标文件夹。⌘N、⇧⌘N 和工具栏传 `FileTree.currentFolder(tree, highlighted)`，右键传该文件夹。`id` 要包含类型和路径。
- 新建后：`setExpandedFolders(展开 ∪ ancestors(新路径))`，`highlighted = 新路径`。
- 重命名和删除处理同 Task 3 Step 3，`selection` 的现有逻辑不变。
- `load()` 只取 `NoteIndex.tree` 和冲突数，`LoadKey` 把 `folder`、`sort` 换成 `fileSort`。
- 右栏空状态：`tree.isEmpty` 时「点工具栏上的「新建笔记」写第一篇。」，否则「选一篇笔记」。

- [ ] **Step 3: 更新调试命令**

`folder <path>` 改成设置 `highlighted`，同步更新 `DebugHooks.swift` 的说明注释。

- [ ] **Step 4: 删除无用代码**

删 `optionalChildren`、`NoteIndex.Note`、`notes`、`preview` 及其辅助函数、`visibleFiles`（确认没有其他调用方）和对应测试。文件头注释改成只描述文件树。

- [ ] **Step 5: 确认测试和构建通过**

Run: `scripts/build-mac.sh --test`，再运行 `scripts/build-mac.sh --debug`
Expected: 测试全部通过，App 能构建

- [ ] **Step 6: 提交**

```bash
git add mac
git commit -m "Make the Mac window two columns with the file tree as navigation"
```

---

### Task 7: Mac 的编辑/预览

**Files:**
- Modify: `mac/Sources/UI/Editor.swift:56,62-66,107-108,187-213`、`mac/Sources/UI/MainWindow.swift`、`mac/Sources/UI/App.swift:68-76`、`mac/Sources/UI/Setup.swift:28-33`

**Interfaces:**
- Consumes: Task 1 的 `setReadonly`、Task 5 的 `ViewMode`、`setDefaultViewMode`
- Produces: `Notification.Name.toggleViewMode`；`EditorController.setReadonly(_ readonly: Bool)`；`RichEditor` 新增 `readonly: Bool` 参数

- [ ] **Step 1: `EditorController` 的 `readonly` 改成可变**

`let readonly` 改成 `private(set) var`。`setReadonly` 更新它并执行 `window.JitnoteEditor && window.JitnoteEditor.setReadonly(...)`；`"ready"` 消息读最新值。`RichEditor.makeNSView` 传入 `readonly`，`updateNSView` 在值变化时调 `setReadonly`。

- [ ] **Step 2: `NotebookView` 记录当前模式**

`@State viewMode: ViewMode`。所有改变 `selection` 的地方都走一个函数 `show(_ path: String, mode: ViewMode? = nil)`：设 `selection`，并把 `viewMode` 设成 `mode ?? notebooks.state.defaultViewMode`。新建笔记传 `.edit`。文件的 `onOpenFile`、调试命令 `select` 走默认。同步后 `NoteDetail` 重建时读同一个 `viewMode`，所以模式保留。

把 `readonly: viewMode == .preview` 经 `NoteDetail` 传给 `RichEditor`。

- [ ] **Step 3: 切换按钮和快捷键**

- 工具栏在历史版本按钮旁加切换按钮，只在 `md`、`markdown` 文件上显示，提示文字写明 ⌘E。
- `App.swift` 加菜单项「切换编辑/预览」，`.keyboardShortcut("e")`，发 `.toggleViewMode`。
- `NotebookView` 收到通知后，只有当前打开的是 Markdown 笔记才切换 `viewMode`。

- [ ] **Step 4: 设置**

在 `GeneralSettingsView` 的 `Form` 里加 `Picker`，标题「打开笔记时默认为」，说明「新建的笔记和纯文本文件总是编辑。」，选项「编辑」「预览」，绑定 `defaultViewMode` 和 `setDefaultViewMode`。

- [ ] **Step 5: 确认测试和构建通过**

Run: `scripts/build-mac.sh --test`，再运行 `scripts/build-mac.sh --debug`
Expected: 测试全部通过，App 能构建

- [ ] **Step 6: 提交**

```bash
git add mac
git commit -m "Add the default view setting and a preview toggle on the Mac"
```

---

### Task 8: 文档和整体验证

**Files:**
- Modify: `README.md:40,61`、`README.en.md:40,61`、`docs/design.md:48-57`（「首页」一节，也去掉「参考印象笔记」的说法，并写入默认打开方式）、`docs/superpowers/specs/2026-10-31-mac-client-design.md:14-19`（改成两栏）

- [ ] **Step 1: 更新上面的文档**

内容按设计文档。两个 README 的第 40 行改为描述全屏文件树、点文件夹展开、设置里的默认打开方式；第 61 行改成两栏，并加上 ⌘E。

- [ ] **Step 2: 跑 CI 的全部命令**

Run: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
Run: `cd editor && npm test`
Run: `scripts/build-mac.sh --test`
Expected: 全部通过

- [ ] **Step 3: 实际运行 Mac 版走一遍**

用 `scripts/build-mac.sh --debug` 和 `DebugHooks`（或 `run` 技能）逐项确认并截图：

1. 点文件夹能展开，再点能收起，空文件夹也有反应；重启后展开状态还在。
2. 高亮文件夹、高亮文件、无高亮时新建，位置都正确，弹窗标题正确；新建后自动展开并高亮。
3. 重命名和删除展开中的文件夹后，树的状态正确。
4. 有冲突时左栏能看到入口（`NotebookGitTests` 的做法可造冲突）。
5. 默认设为预览：点笔记只读且无格式工具栏；⌘E 和按钮能切换；待办复选框点不动；图片能看大图，链接在浏览器打开；新建笔记和 `.txt` 是编辑状态。
6. 预览里打开再离开，`git status` 显示文件没有改动。
7. 打完字立刻切预览，内容保存到了文件。

- [ ] **Step 4: 实际运行安卓版走一遍**

在模拟器上安装 debug 包，走同样 7 项，另外确认：

- 打开笔记再返回，滚动位置不变且不闪白。
- 切到预览时键盘收起。
- 首页按返回键退出 App。

没有可用的模拟器时，在任务报告里明确写出这一步没做，不要当作通过。

- [ ] **Step 5: 提交**

```bash
git add README.md README.en.md docs
git commit -m "Describe the file tree navigation and default view in the docs"
```
