# Git 笔记本（git-notebook）

把笔记放进**你自己的** Gitee / GitHub 私有仓库里的手机笔记 App。完全开源，没有服务器，不收集任何数据。

- **每个笔记本就是一个真正的 Git 仓库**：手机上有完整的 `.git`、真实的提交历史。在电脑上 `git clone` 下来，用任何编辑器或 AI 工具（Cursor、Claude Code……）改完推上去，手机点一下同步就能拿到。
- **只有一个「同步」按钮**：自动保存、自动记录版本，同步 = 提交 → 拉取 → 合并 → 推送。从不强推。
- **冲突不丢数据**：同一篇笔记两边都改了，自动保留较新的版本；另一个版本留在历史里，一键就能换回去。
- **所见即所得**：用户看到的是普通笔记（标题、加粗、列表、待办、表格），存下来的是标准 Markdown，Obsidian / Typora 也能直接打开。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| [`android/`](android/) | Android 客户端（Kotlin + Jetpack Compose + [JGit](https://www.eclipse.org/jgit/)） |
| [`editor/`](editor/) | 所有客户端共用的笔记编辑器（[Milkdown](https://milkdown.dev/) Crepe，打包成离线网页嵌入 App） |
| [`docs/`](docs/) | 设计说明 |

以后的 iOS、桌面端也放在这个仓库里，复用 `editor/`，并遵循同一套同步规则（见 [docs/design.md](docs/design.md)）。

## 使用方法（Android）

1. 安装 App，点「连接云端账号」，按页面上的步骤在 Gitee（推荐）或 GitHub 生成一个令牌，粘贴进来。
2. 点「添加笔记本 → 新建」，起个名字。App 会在你的账号里建一个**私有**仓库。
3. 写笔记。写完返回就自动保存；点右上角的同步按钮上传到云端。
4. 已经有放笔记的仓库（比如 Obsidian 的）？「添加笔记本 → 用已有的」里直接选它，原有文件原样保留。
5. 换手机或第二台手机：连接同一个账号后，同样在「用已有的」里挑选笔记本。

令牌所需权限：Gitee 私人令牌保持默认勾选（至少 `user_info`、`projects`）；GitHub classic token 勾选 `repo`。令牌只用 Android Keystore 加密保存在手机上。

## 开发

### Android

需要 JDK 17 和 Android SDK 35。

```bash
cd android
./gradlew :app:testDebugUnitTest   # 同步引擎测试（用本地 bare 仓库模拟云端）
./gradlew :app:assembleDebug       # 调试包
./gradlew :app:assembleRelease     # 正式包（目前用调试签名，方便自己安装）
```

`android/app/src/main/assets/editor/` 是 `editor/` 的构建产物，已经提交到仓库，所以只改 Android 代码时不需要 Node。

### 编辑器

需要 Node 20+。

```bash
cd editor
npm install
npm run dev     # 浏览器里调试（没有宿主时会加载示例笔记）
npm test        # 打开再保存不改变笔记（含 Obsidian 写法）
npm run build   # 输出到 android/app/src/main/assets/editor/
```

### 调试构建的本地测试服务器

debug 包允许用明文 http 访问模拟器宿主机 `10.0.2.2`（见 `android/app/src/debug/`），方便用本机的 `git http-backend` 做端到端测试，正式包不受影响。

## 许可证

[Apache License 2.0](LICENSE)
