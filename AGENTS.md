# AGENTS.md

在这个仓库里改记特时先读本文件。产品行为以 [docs/design.md](docs/design.md) 为准，构建、运行和发布以 [README.md](README.md) 为准。本文件不重复那两处的正文。

## 项目

记特把用户自己的 GitHub / Gitee 私有仓库当作笔记本。没有自有服务器。Android 在 `android/`（Kotlin、Jetpack Compose、JGit 5.13），Mac 在 `mac/`（Swift、SwiftUI、libgit2），两边共用 `editor/` 里的 Milkdown 编辑器。

## 改代码前

- 改同步、冲突、编辑器或文件如何打开时，先读 [docs/design.md](docs/design.md)。行为变了，同一轮改掉设计说明里对应的句子。
- 界面文案用设计说明里的说法：笔记本、同步、历史版本、云端账号。不出现 Git、Markdown、仓库、提交、分支、push、merge。
- Android 和 Mac 的同步规则保持一致。改一边的同步行为，另一边和对应测试一起改。
- 只改要解决的问题。不顺手重排，不改无关文件。

## 不能破的行为

- 同步是提交、拉取、合并、推送。用 merge，不用 rebase，从不强推。
- 用户没改过的笔记，打开再保存必须逐字节不变。编辑器只在真正编辑后回写。
- 不改用户仓库里已有的东西来迁就 App：遵守仓库已有的 `.gitignore`；App 的元数据只放 `.jitnote/`（随仓库同步）和 `.git/jitnote/`（仅本机）。导入已有仓库时不写入任何文件。
- 删除笔记本只删本机副本。
- 令牌只留在设备上。不要把令牌、密钥、`local.properties` 写进仓库。正式签名密钥不能换。
- 版本号只由 `scripts/release.sh` 改。不要为了一次功能提交去改 `appVersion`。

## 编辑器

`editor/` 是源码。`android/app/src/main/assets/editor/` 是 `npm run build` 的产物，Mac 打包时复制这份产物。改了 `editor/` 就要在 `editor/` 里跑 `npm test` 和 `npm run build`，并把新的产物一起提交。不要手改 `assets/editor/` 里的打包文件。

## 验证

- Android：`cd android && ./gradlew :app:testDebugUnitTest`。需要 JDK 17 和 Android SDK 35。
- Mac：`scripts/build-mac.sh --test`。需要 Homebrew 的 libgit2。
- 编辑器：`cd editor && npm test`。

改了哪一边，就跑哪一边的测试。改了同步，两边都跑。没有设备或模拟器时，不要把界面说成已经在真机上验证过。

## 代码

- 界面字符串用简体中文。代码注释用英文，只写约束，不写复述。
- 跟周围文件的写法。Android 的 Git 调用留在 `NotebookGit` 和 `GitEnvironment`，不要读系统 git 或 `~/.gitconfig`。
