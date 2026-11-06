# Mac 客户端设计

- 日期：2026-10-31
- 分支：`mac-client`（确认前不合并、不发布）

## 目标

在 Mac 上提供和 Android 版操作逻辑一致的记特，原生 Swift / SwiftUI 实现。遵守 [docs/design.md](../../design.md) 的全部产品原则和同步规则：界面不出现 Git 术语、真 Git、没有服务器、不改动用户的东西、从不强推、冲突不丢数据、打开再保存不改变笔记。

**不做**（这一版）：iOS、Intel Mac、应用商店上架、苹果公证、App 自己替换自己。

## 界面

参照 Android 的操作逻辑，改成 Mac 习惯的两栏窗口（`NavigationSplitView`）。最初是三栏（左栏、笔记列表、编辑器），后来按 [向 Obsidian 靠齐的导航和打开方式](../2026-11-02-obsidian-navigation/[spec]obsidian-navigation.md) 去掉了中间的笔记列表，文件树成为唯一的导航：

| 位置 | 内容 | 对应 Android |
| --- | --- | --- |
| 左栏（可收起） | 顶部笔记本切换菜单（含「管理笔记本…」）、同步状态、冲突提示（有冲突时才出现）；「文件列表」：像 Obsidian 一样的文件树：所有文件和文件夹，显示完整文件名（含后缀），文件夹在前、带笔记数。点文件夹展开或收起，点笔记在右栏打开，点图片看大图，其他文件用 Quick Look 预览；右键：历史版本、重命名、在访达中显示、删除，文件夹另有「新建笔记」「新建文件夹」；底部「新建文件夹」 | 首页的文件树 + 标题切换 |
| 右栏 | 选中笔记的编辑器（同一个 `editor/` 网页），⌘E 切换编辑和预览 | 编辑页 |

- 工具栏：同步、新建笔记。菜单：新建笔记 ⌘N、新建文件夹 ⇧⌘N、同步 ⌘R。
- 设置窗口（⌘,）：通用（显示隐藏文件）、管理笔记本、云端账号、检查更新。
- 笔记右键：历史版本、重命名、删除。历史版本、冲突、看大图用弹出窗口（sheet）。
- 没有账号时窗口显示欢迎页；没有笔记本时显示「添加笔记本」。
- 自动保存：编辑停顿后写文件；切换笔记、窗口失去焦点、退出时提交（和 Android「离开笔记时提交」一致）。同步时编辑器只读，同步后重新加载。

## 技术

| 项目 | 选择 |
| --- | --- |
| 语言 / 界面 | Swift 6 / SwiftUI，最低 macOS 14，只支持 Apple 芯片 |
| Git | libgit2（Homebrew 预编译），通过 `mac/CGit2` 模块调用，dylib 打包进 App |
| 同步规则 | 逐条移植 `NotebookGit.kt`，并移植 `NotebookGitTest.kt` 的全部用例 |
| 令牌 | 钥匙串（`kSecClassGenericPassword`，仅本机） |
| 本地数据 | `~/Library/Application Support/Jitnote/`：`state.json`、`notebooks/<id>/` |
| 编辑器 | `WKWebView` 加载 `android/app/src/main/assets/editor/` 的构建产物；自定义 scheme 提供编辑器文件和笔记本里的图片；`resolveFile` 需要同步返回，用 `prompt()` 通道实现 |
| 构建 | `scripts/build-mac.sh` 直接调用 `swiftc`（本机 SwiftPM 不可用，也不需要 Xcode），组装 `.app`、打包 dylib、ad-hoc 签名、打 zip；`--test` 编译并运行测试 |

源码在 `mac/`：`Sources/`（`Core` 同步引擎、`Data` 数据与平台接口、`UI` 界面）、`Tests/`、`CGit2/`、`Resources/`。

## 版本和发布

- 和 Android 共用版本号（`android/app/build.gradle.kts` 的 `appVersion`），`scripts/release.sh` 不变。
- `release.yml` 增加 macOS 任务：在 GitHub 的 Mac 机器上 `brew install libgit2`、运行 `scripts/build-mac.sh`，把 `Jitnote-mac-apple-silicon-x.y.z.dmg`（给人下载：打开就是拖到「应用程序」的窗口）和 `.zip`（给 0.3.0 的检查更新用，它只认 ZIP）上传到同一个 Release。`ci.yml` 增加 Mac 测试。
- 检查更新：和 Android 同样的时机和弹窗；优先下载 Release 里的 Mac DMG，下好后「打开安装包」，用户拖到「应用程序」替换（和第一次安装一样）；只有 ZIP 的旧版本则解压后在访达里显示。
- 没有苹果开发者账号：首次打开需右键「打开」，README 写明。

## 已知限制

- Homebrew 的 libgit2 是为构建机的系统版本编译的，所以 App 需要和构建机同样新的 macOS；`build-mac.sh` 会把这个版本写进 App 的最低系统要求，旧系统上会直接提示无法打开，而不是闪退。以后改为自己编译 libgit2，就能支持更老的系统。
- 只有 Apple 芯片（arm64）。
- 只做 ad-hoc 签名，每个版本的签名都不同，所以更新后第一次读取令牌时钥匙串会询问一次（点「始终允许」）。以后可以改用固定的自签名证书签名，钥匙串就能认出是同一个 App。读取令牌放在后台线程，询问时窗口不会卡住。
- 自动化测试截不到 macOS 26 的玻璃材质侧边栏和工具栏（`DebugHooks` 的截图里是白色），这两处需要人工看一眼。
