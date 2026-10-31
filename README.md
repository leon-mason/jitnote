# Git 笔记本（git-notebook）

简体中文 | [English](README.en.md)

把笔记放进**你自己的** Gitee / GitHub 私有仓库里的手机笔记 App。完全开源，没有服务器，不收集任何数据。

- **每个笔记本就是一个真正的 Git 仓库**：手机上有完整的 `.git`、真实的提交历史。在电脑上 `git clone` 下来，用任何编辑器或 AI 工具（Cursor、Claude Code……）改完推上去，手机点一下同步就能拿到。
- **只有一个「同步」按钮**：自动保存、自动记录版本，同步 = 提交 → 拉取 → 合并 → 推送。从不强推。
- **冲突不丢数据**：同一篇笔记两边都改了，自动保留较新的版本；另一个版本留在历史里，一键就能换回去。
- **所见即所得**：用户看到的是普通笔记（标题、加粗、列表、待办、表格），存下来的是标准 Markdown，Obsidian / Typora 也能直接打开。
- **能用已有的仓库**：Obsidian、Typora 的笔记仓库可以直接拿来用，原有文件和图片写法原样保留。

> **项目状态**：早期版本，有 Android 客户端和 Mac 客户端（Mac 版刚开始测试）。欢迎试用和反馈，重要笔记请先在电脑上留一份备份。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| [`android/`](android/) | Android 客户端（Kotlin + Jetpack Compose + [JGit](https://www.eclipse.org/jgit/)） |
| [`mac/`](mac/) | Mac 客户端（Swift + SwiftUI + [libgit2](https://libgit2.org/)） |
| [`editor/`](editor/) | 所有客户端共用的笔记编辑器（[Milkdown](https://milkdown.dev/) Crepe，打包成离线网页嵌入 App） |
| [`docs/`](docs/) | 设计说明 |

以后的 iOS 等客户端也放在这个仓库里，复用 `editor/`，并遵循同一套同步规则（见 [docs/design.md](docs/design.md)）。

## 使用方法（Android）

支持 Android 8.0 及以上。在 [Releases](https://github.com/leon-mason/git-notebook/releases/latest) 下载最新的 `git-notebook-x.y.z.apk` 安装。

1. 打开 App，点「连接云端账号」，按页面上的步骤在 Gitee（推荐）或 GitHub 生成一个令牌，粘贴进来。
2. 点「添加笔记本 → 新建」，起个名字。App 会在你的账号里建一个**私有**仓库。
3. 写笔记。写完返回就自动保存；点右上角的同步按钮上传到云端。
4. 已经有放笔记的仓库（比如 Obsidian 的）？「添加笔记本 → 用已有的」里直接选它，原有文件原样保留。
5. 换手机或第二台手机：连接同一个账号后，同样在「用已有的」里挑选笔记本。

首页显示当前笔记本里的**全部笔记**（不分文件夹），可以按修改时间或标题排序。在屏幕上任意位置向右滑、或点左上角 ☰，打开文件夹目录，点文件夹只看里面的笔记。点顶部的笔记本名字切换笔记本，或进入「管理笔记本」。

删除笔记本只删除手机上的副本，云端仓库不受影响。

有新版本时，打开 App 会提示更新（每天最多查一次），也可以在首页右上角「⋮ → 检查更新」手动查。

### 令牌和隐私

- 令牌所需权限：Gitee 私人令牌保持默认勾选（至少 `user_info`、`projects`）；GitHub classic token 勾选 `repo`。
- 这些权限能读写你账号下的**所有**仓库，请只在自己的手机上使用，不用时可以随时在 Gitee / GitHub 的设置里删除令牌。
- 令牌用 Android Keystore 加密后只保存在手机上，App 关闭了系统备份；Mac 版保存在本机的钥匙串里。
- App 只和你自己的 Gitee / GitHub 通信。唯一的例外是检查更新：每天最多一次，匿名查询本项目在 GitHub 上有没有新版本，不带令牌，也不发送任何笔记内容。没有统计和广告。

## 使用方法（Mac）

需要 Apple 芯片的 Mac，以及较新的 macOS（目前和打包用的系统版本一致；系统太旧时会直接提示无法打开）。

1. 在 [Releases](https://github.com/leon-mason/git-notebook/releases/latest) 下载 `GitNotebook-mac-x.y.z.zip`，解压后把「Git 笔记本」拖到「应用程序」文件夹。
2. 第一次打开：在「应用程序」里**右键点它 → 打开**，再点「打开」。因为没有苹果开发者签名，直接双击会被系统拦下，只有第一次需要这样做。
3. 连接账号、添加笔记本的步骤和 Android 一样。窗口分三栏：左边是笔记本切换和文件夹，中间是笔记列表，右边是正在写的笔记。⌘N 新建笔记，⌘R 同步。
4. 有新版本时会提示更新：下载好后按提示把新版拖到「应用程序」替换即可。更新后第一次同步，系统可能询问是否允许访问钥匙串里的令牌，点「始终允许」。

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
scripts/build-mac.sh --run    # 构建 mac/build/GitNotebook.app 并打开
```

`--debug` 构建带测试用遥控的版本（见 [`DebugHooks.swift`](mac/Sources/UI/DebugHooks.swift)），用来在没有屏幕录制权限的机器上自动操作和截图；它的令牌存在文件里，不碰钥匙串。设计见 [Mac 客户端设计](docs/superpowers/specs/2026-10-31-mac-client-design.md)。

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

脚本会打开编辑器让你写更新内容（App 的更新提示里显示的就是这段话，编辑器里附了上次发版以来的提交供参考），确认后自动：把 [`android/app/build.gradle.kts`](android/app/build.gradle.kts) 里的 `appVersion` 加一个小版本（如 `0.2.0 → 0.3.0`）、提交、打标签、推送，并等 GitHub Actions 测试、签名、打包 APK 和 Mac 版、在 [Releases](https://github.com/leon-mason/git-notebook/releases) 发布完成。

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

用到的主要第三方组件及其许可证：[JGit](https://www.eclipse.org/jgit/)（EDL 1.0）、[Milkdown](https://milkdown.dev/)（MIT）、[DOMPurify](https://github.com/cure53/DOMPurify)（Apache 2.0 / MPL 2.0）、AndroidX / Jetpack Compose（Apache 2.0）。
