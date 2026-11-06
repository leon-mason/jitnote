# 记特 Jitnote

简体中文 | [English](README.en.md)

「记特」读作 Git：把笔记放进**你自己的** GitHub / Gitee 私有仓库，手机（Android）、Mac 和 Windows 11 上都能写。

- **数据主权**：笔记只在你自己的仓库和设备上，账号、令牌、内容都不经过任何第三方。
- **无需服务器**：没有我们的服务器，也不需要你自己搭；完全开源，不收集任何数据。
- **AI 协同维护和查询**：笔记是普通的 Markdown 文件、真正的 Git 仓库。Claude Code、Cursor 等 AI 工具可以直接帮你整理、改写、查询，改完推上去，手机点一下同步就能看到。

- **每个笔记本就是一个真正的 Git 仓库**：手机上有完整的 `.git`、真实的提交历史。在电脑上 `git clone` 下来，用任何编辑器或 AI 工具（Cursor、Claude Code……）改完推上去，手机点一下同步就能拿到。
- **只有一个「同步」按钮**：笔记随写随存，同步时记录版本并上传：提交 → 拉取 → 合并 → 推送。从不强推。
- **冲突不丢数据**：同一篇笔记两边都改了，同步时列出来让你选以哪边为准；没选中的那一版留在历史里，随时能找回。
- **所见即所得**：用户看到的是普通笔记（标题、加粗、列表、待办、表格），存下来的是标准 Markdown，Obsidian / Typora 也能直接打开。
- **能用已有的仓库**：Obsidian、Typora 的笔记仓库可以直接拿来用，原有文件和图片写法原样保留。

> **项目状态**：早期版本，有 Android 客户端、Mac 客户端和 Windows 11 客户端。欢迎试用和反馈，重要笔记请先在电脑上留一份备份。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| [`android/`](android/) | Android 客户端（Kotlin + Jetpack Compose + [JGit](https://www.eclipse.org/jgit/)） |
| [`mac/`](mac/) | Mac 客户端（Swift + SwiftUI + [libgit2](https://libgit2.org/)） |
| [`windows/`](windows/) | Windows 11 客户端（C# / .NET + Avalonia + [LibGit2Sharp](https://github.com/libgit2/libgit2sharp)） |
| [`editor/`](editor/) | 所有客户端共用的笔记编辑器（[Milkdown](https://milkdown.dev/) Crepe，打包成离线网页嵌入 App） |
| [`docs/`](docs/) | 设计说明 |

以后的 iOS 等客户端也放在这个仓库里，复用 `editor/`，并遵循同一套同步规则（见 [docs/design.md](docs/design.md)）。

## 使用方法（Android）

支持 Android 8.0 及以上。在 [Releases](https://github.com/leon-mason/jitnote/releases/latest) 下载最新的 `jitnote-x.y.z.apk` 安装。

1. 打开 App，点「连接云端账号」，按页面上的步骤在 Gitee（推荐）或 GitHub 生成一个令牌，粘贴进来。
2. 点「添加笔记本 → 新建」，起个名字。App 会在你的账号里建一个**私有**仓库。
3. 写笔记。写完返回就自动保存；点右上角的同步按钮上传到云端。
4. 已经有放笔记的仓库（比如 Obsidian 的）？「添加笔记本 → 用已有的」里直接选它，原有文件原样保留。
5. 换手机或第二台手机：连接同一个账号后，同样在「用已有的」里挑选笔记本。

首页就是当前笔记本的**文件树**，和 Obsidian 一样列出所有文件和文件夹，显示完整文件名。点文件夹展开或收起（空文件夹也能点），点文件直接打开，展开了哪些文件夹下次还记得。新建笔记和新建文件夹都建在当前高亮的位置里。点顶部的笔记本名字切换笔记本，或进入「管理笔记本」。打开笔记时默认是编辑还是预览，可以在「⋮ → 设置」里选，打开后也能随时在顶栏切换；预览是只读的，不会改动文件。Markdown 笔记的右上角可以打开大纲，在预览左侧按标题跳转。

以 . 开头的隐藏文件（如 `.obsidian`、`.gitignore`）默认不显示，可以在「⋮ → 设置」（Mac 版在「设置 → 通用」，Windows 版在「设置」）里打开；Git 自己的 `.git` 始终不显示。同一个设置页可以打开「启动时自动同步」：打开 App，或离开超过一分钟后再回来，会自动同步当前笔记本。没有变化时不额外提示。

删除笔记本只删除手机上的副本，云端仓库不受影响。

有新版本时，打开 App 会提示更新（每天最多查一次），也可以在首页右上角「⋮ → 检查更新」手动查。

### 令牌和隐私

- 令牌所需权限：Gitee 私人令牌保持默认勾选（至少 `user_info`、`projects`）；GitHub classic token 勾选 `repo`。
- 这些权限能读写你账号下的**所有**仓库，请只在自己的手机上使用，不用时可以随时在 Gitee / GitHub 的设置里删除令牌。
- 令牌用 Android Keystore 加密后只保存在手机上，App 关闭了系统备份；Mac 版保存在本机的钥匙串里；Windows 版保存在当前用户的凭据管理器里，只存在这台电脑上，不随账户漫游。
- App 只和你自己的 Gitee / GitHub 通信。唯一的例外是检查更新：每天最多一次，匿名查询本项目在 GitHub 上有没有新版本，不带令牌，也不发送任何笔记内容。没有统计和广告。

## 使用方法（Mac）

需要 Apple 芯片的 Mac，以及较新的 macOS（目前和打包用的系统版本一致；系统太旧时会直接提示无法打开）。

1. 在 [Releases](https://github.com/leon-mason/jitnote/releases/latest) 下载 `Jitnote-mac-apple-silicon-x.y.z.dmg`，双击打开，在弹出的窗口里把「记特」拖到「应用程序」。
2. 第一次打开：在「应用程序」里**右键点它 → 打开**，再点「打开」。因为没有苹果开发者签名，直接双击会被系统拦下，只有第一次需要这样做。
3. 连接账号、添加笔记本的步骤和 Android 一样。窗口分两栏：左边是笔记本切换和文件树（点文件夹展开或收起，点文件打开），右边是正在写的笔记。⌘N 新建笔记，⌘R 同步，⌘E 在编辑和预览之间切换（默认打开方式在「设置 → 通用」里选）。
4. 有新版本时会提示更新：下载好后点「退出并安装」，记特会自动退出并打开安装包，和第一次安装一样把新版拖到「应用程序」，选择「替换」即可。更新后第一次同步，系统可能询问是否允许访问钥匙串里的令牌，点「始终允许」。

**笔记本放在哪里**：添加笔记本时会显示保存位置，默认是 `~/Jitnote/<仓库名>`，点「更改…」可以换成你自己的**空文件夹**（选择窗口里能新建文件夹）。创建后位置不能更改。点左栏顶部的笔记本名字，选「打开文件夹」就能在访达里看到它，选「复制路径」就能把路径交给 Claude Code、Cursor 等 AI 工具当项目目录——这个文件夹就是一个普通的 Git 仓库，AI 改了文件甚至自己提交了都没关系，回到记特点同步就会上传；记特打开着的笔记被别的程序改了，会直接显示新内容。不要把笔记本放进 iCloud 云盘或 Dropbox 这类会自动同步的位置，它们会和笔记本自己的同步互相干扰。移除笔记本时，放在默认位置的文件夹会一起删除；你自己选的文件夹原样保留。

## 使用方法（Windows）

需要 Windows 11，64 位。不支持 Windows 10 及更早，这一版也没有 ARM 包。

1. 在 [Releases](https://github.com/leon-mason/jitnote/releases/latest) 下载 `Jitnote-windows-x64-x.y.z.exe`，放在你想放的地方。它是单个文件，不用解压，也不用安装。同一页的 `.zip` 只给旧版记特检查更新用，不用下载。
2. 双击下载的 exe。如果系统提示「Windows 已保护你的电脑」或发布者不明：点「更多信息」，再点「仍要运行」。这个程序没有购买代码签名，只有第一次会这样问。
3. 连接账号、添加笔记本的步骤和 Android 一样。窗口分两栏：左边是笔记本切换和文件树，右边是正在写的笔记。Ctrl+N 新建笔记，Ctrl+Shift+N 新建文件夹，Ctrl+R 同步，Ctrl+E 在编辑和预览之间切换（光标在编辑器里时同样生效），Ctrl+，打开设置。
4. 有新版本时会提示更新：下载完会打开新 exe 所在的位置。先退出记特，再用新的 exe 替换现在的。记特还开着的时候不要覆盖它。

**笔记本放在哪里**：添加笔记本时会显示保存位置，默认是用户主目录下的 `Jitnote\<仓库名>`，点「更改…」可以换成你自己的**空文件夹**。`desktop.ini` 和 `Thumbs.db` 不算有内容。创建后位置不能更改。设置里可以在文件资源管理器中打开，或复制路径。不要把笔记本放进 OneDrive、Dropbox 或 iCloud 这类会自动同步的位置。移除笔记本时，放在默认位置的文件夹会一起删除；你自己选的文件夹原样保留。云端不受影响。找不到文件夹时，可以重新检查、重新选择原来的文件夹，或重新下载到原位置。

## 开发

### Android

需要 JDK 17 和 Android SDK 35。

```bash
cd android
./gradlew :app:testDebugUnitTest   # 同步引擎测试（用本地 bare 仓库模拟云端）
./gradlew :app:assembleDebug       # 调试包
./gradlew :app:assembleRelease     # 正式包（本地构建用调试签名，方便自己安装）
```

`android/app/src/main/assets/editor/` 是 `editor/` 的构建产物，已经提交到仓库，所以只改 Android 代码时不需要 Node。改了 `editor/` 后记得重新 `npm run build` 并一起提交。

### Mac

不需要 Xcode，只要命令行工具和 Homebrew 的 libgit2：

```bash
brew install libgit2
scripts/build-mac.sh --test   # 同步引擎等测试（和 Android 的测试用例一一对应）
scripts/build-mac.sh --run    # 构建 mac/build/Jitnote.app 并打开
```

`--debug` 构建带测试用遥控的版本（见 [`DebugHooks.swift`](mac/Sources/UI/DebugHooks.swift)），用来在没有屏幕录制权限的机器上自动操作和截图；它的令牌存在文件里，不碰钥匙串。设计见 [Mac 客户端设计](docs/requirements/2026-10-31-mac-client/[spec]mac-client.md)。

### Windows

需要 .NET 8 SDK。在 Mac 或 Linux 上就能编译并打出 Windows 11 的 exe，不必有一台 Windows：

```bash
scripts/build-windows.sh --test   # 同步等测试（和 Mac 的用例对应）
scripts/build-windows.sh          # windows/build/Jitnote-windows-x64-<版本>.exe（以及给旧版更新用的 .zip）
```

在 Mac 上跑界面时没有 Windows 的凭据管理器，令牌写在应用数据目录里单独的 `tokens.json`，不进笔记本，也不进状态文件。打出来的 Windows 包用凭据管理器。编辑器在 Windows 11 的 WebView2 里打开；在 Mac 上编译时这一层不参与，界面用文本框代替，保存规则相同。

### 编辑器

需要 Node 20+。

```bash
cd editor
npm install
npm run dev     # 浏览器里调试（没有宿主时会加载示例笔记）
npm test        # 打开再保存不改变笔记（含 Obsidian 写法）
npm run build   # 输出到 android/app/src/main/assets/editor/
```

### 发布新版本

在 `main` 分支上，所有改动都提交并推送后运行：

```bash
scripts/release.sh
```

脚本会打开编辑器让你写更新内容（App 的更新提示里显示的就是这段话，编辑器里附了上次发版以来的提交供参考），确认后自动：把 [`android/app/build.gradle.kts`](android/app/build.gradle.kts) 里的 `appVersion` 加一个小版本（如 `0.2.0 → 0.3.0`）、提交、打标签、推送，并等 GitHub Actions 测试、签名、打包 APK、Mac 版和 Windows 11 包、在同一次 [Releases](https://github.com/leon-mason/jitnote/releases) 发布完成。已经发出去的旧版本不会补 Windows 包。不上架应用商店。

- `scripts/release.sh -n` 只预览版本号和提交，不做改动；`-m "更新内容"` 直接给出更新内容；`-y` 跳过确认。
- **升级大版本**：把 `scripts/release.sh` 开头的 `MAJOR` 改大（如 `2`）并提交，下次发版就是 `2.0.0`，之后是 `2.1.0`、`2.2.0`……
- 脚本会拒绝这些情况：不在 `main`、有没提交的改动、和 GitHub 不一致、上次发版后没有新提交、改了 `editor/` 却没重新 `npm run build`。

正式签名密钥保存在仓库的 Secrets（`RELEASE_KEYSTORE_BASE64`、`RELEASE_KEYSTORE_PASSWORD`）里。**密钥必须一直用同一把**，换了密钥，已安装的 App 就无法更新。

### 调试构建的本地测试服务器

debug 包允许用明文 http 访问模拟器宿主机 `10.0.2.2`（见 `android/app/src/debug/`），方便用本机的 `git http-backend` 做端到端测试，正式包不受影响。

## 参与贡献

欢迎提 Issue 和 Pull Request。改动同步逻辑或编辑器前，请先读 [docs/design.md](docs/design.md)：界面不出现 Git 术语、从不强推、打开再保存不改变笔记，这几条是硬性约定，相关测试需要保持通过。

## 许可证

本项目使用 [Apache License 2.0](LICENSE)。

Git 是 Software Freedom Conservancy 的注册商标；「记特 / Jitnote」只是取了它的读音，本项目与 Git 项目没有关联。

用到的主要第三方组件及其许可证：[JGit](https://www.eclipse.org/jgit/)（EDL 1.0）、[libgit2](https://libgit2.org/)（GPL-2.0，带链接例外）、[LibGit2Sharp](https://github.com/libgit2/libgit2sharp)（MIT）、[Milkdown](https://milkdown.dev/)（MIT）、[DOMPurify](https://github.com/cure53/DOMPurify)（Apache 2.0 / MPL 2.0）、AndroidX / Jetpack Compose（Apache 2.0）、[Avalonia](https://avaloniaui.net/)（MIT）。
