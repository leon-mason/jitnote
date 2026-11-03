# 记特 Jitnote

[简体中文](README.md) | English

Jitnote (记特, pronounced like "Git") keeps your notes in **your own** private GitHub / Gitee repositories, on Android and on the Mac.

- **Your data stays yours**: notes live only in your own repositories and devices; accounts, tokens and content never pass through a third party.
- **No server**: there is no server of ours, and you don't need one either. Fully open source, no data collection.
- **Built for working with AI**: notes are plain Markdown files in a real Git repository, so AI tools such as Claude Code or Cursor can organize, rewrite and search them directly; push, tap sync on the phone, and the changes are there.

- **Every notebook is a real Git repository**: the phone keeps a full `.git` with real commit history. Clone it on your computer, edit with any editor or AI tool (Cursor, Claude Code, …), push, and tap sync on the phone to get the changes.
- **Just one "Sync" button**: notes are saved as you write; sync records a version and uploads it: commit → fetch → merge → push. Never force-pushes.
- **Conflicts never lose data**: if the same note was edited in two places, the newer version is kept. The other version stays in history and can be restored with one tap.
- **WYSIWYG**: you see an ordinary note (headings, bold, lists, to-dos, tables). What's saved is standard Markdown that Obsidian / Typora can open directly.
- **Works with existing repositories**: use your Obsidian or Typora notes repository as-is. Existing files and image references are left untouched.

> **Status**: early version. There is an Android client and a Mac client (the Mac one is new), and the UI is Chinese only. Feedback is welcome; please keep a backup of important notes on your computer.

## Repository layout

| Directory | Contents |
| --- | --- |
| [`android/`](android/) | Android client (Kotlin + Jetpack Compose + [JGit](https://www.eclipse.org/jgit/)) |
| [`mac/`](mac/) | Mac client (Swift + SwiftUI + [libgit2](https://libgit2.org/)) |
| [`editor/`](editor/) | Note editor shared by all clients ([Milkdown](https://milkdown.dev/) Crepe, bundled as an offline web page embedded in the app) |
| [`docs/`](docs/) | Design notes (in Chinese) |

Future clients such as iOS will live in this repository too, reuse `editor/`, and follow the same sync rules (see [docs/design.md](docs/design.md)).

## Usage (Android)

Requires Android 8.0 or later. Download the latest `jitnote-x.y.z.apk` from [Releases](https://github.com/leon-mason/jitnote/releases/latest) and install it.

1. Open the app, tap "连接云端账号" (Connect cloud account), follow the on-screen steps to create a token on Gitee or GitHub, and paste it in.
2. Tap "添加笔记本 → 新建" (Add notebook → New) and give it a name. The app creates a **private** repository in your account.
3. Write notes. They're saved automatically when you leave a note; tap the sync button in the top-right corner to upload them.
4. Already have a notes repository (e.g. from Obsidian)? Pick it under "添加笔记本 → 用已有的" (Add notebook → Use existing). Existing files are kept as they are.
5. New or second phone: connect the same account, then pick your notebooks under "用已有的" (Use existing).

The home screen is the **file tree** of the current notebook: like Obsidian, it shows every file and folder with full names. Tap a folder to expand or collapse it (empty folders too) and a file to open it; the app remembers which folders are expanded. New notes and new folders are created at the highlighted location. Tap the notebook name at the top to switch notebooks or open "管理笔记本" (Manage notebooks). Whether a note opens for editing or in preview is set under "⋮ → 设置" (Settings), and you can switch at any time from the top bar once it is open; preview is read-only and never changes the file.

Hidden files starting with "." (such as `.obsidian` and `.gitignore`) are not shown unless you turn on "显示隐藏文件" in "⋮ → 设置" (on the Mac: Settings → 通用). Git's own `.git` folder is never shown.

Deleting a notebook only removes the copy on the phone; the repository in the cloud is not affected.

When a new version is out, the app offers to update when you open it (it checks at most once a day). You can also check by hand from the home screen's "⋮ → 检查更新" (Check for updates).

### Tokens and privacy

- Required token permissions: for a Gitee personal token, keep the default selection (at least `user_info` and `projects`); for a GitHub classic token, select `repo`.
- These permissions grant read/write access to **all** repositories in your account. Only use the token on your own phone, and delete it in your Gitee / GitHub settings whenever you no longer need it.
- The token is encrypted with the Android Keystore and stored only on the phone, with system backup disabled. On the Mac it is kept in the local keychain.
- The app only talks to your own Gitee / GitHub account. The one exception is the update check: at most once a day, it asks this project's GitHub page anonymously whether there is a new version. No token and no note content is sent. There are no analytics or ads.

## Usage (Mac)

Requires a Mac with Apple silicon and a recent macOS (currently the same version as the build machine; on an older system macOS says the app can't be opened).

1. Download `Jitnote-mac-apple-silicon-x.y.z.dmg` from [Releases](https://github.com/leon-mason/jitnote/releases/latest), open it, and drag "记特" onto Applications in the window that appears.
2. The first time: in Applications, **right-click it → Open**, then click Open. It has no Apple developer signature, so a plain double-click is blocked; this is only needed once.
3. Connecting an account and adding notebooks work as on Android. The window has two columns: the notebook switcher and the file tree (click a folder to expand or collapse it, a file to open it), and the open note. ⌘N creates a note, ⌘R syncs, ⌘E switches between editing and preview (the default is set under Settings → 通用).
4. When a new version is out, the app offers to download it; click "打开安装包" (Open installer) and drag the new app onto Applications, as when installing, choosing Replace. On the first sync after an update, macOS may ask whether the app may use the token in your keychain — click "Always Allow".

## Development

### Android

Requires JDK 17 and Android SDK 35.

```bash
cd android
./gradlew :app:testDebugUnitTest   # sync engine tests (a local bare repository stands in for the cloud)
./gradlew :app:assembleDebug       # debug build
./gradlew :app:assembleRelease     # release build (local builds are signed with the debug key for easy self-install)
```

`android/app/src/main/assets/editor/` is the build output of `editor/` and is committed, so you don't need Node if you only change Android code. After changing `editor/`, run `npm run build` again and commit the output together with your change.

### Mac

No Xcode needed — just the Command Line Tools and Homebrew's libgit2:

```bash
brew install libgit2
scripts/build-mac.sh --test   # sync engine and other tests (the same cases as Android's)
scripts/build-mac.sh --run    # builds mac/build/Jitnote.app and opens it
```

`--debug` builds a version with a test-only remote control (see [`DebugHooks.swift`](mac/Sources/UI/DebugHooks.swift)) for driving and photographing the window on machines without screen-recording access; it keeps tokens in a file and never touches the keychain. Design: [Mac client design](docs/superpowers/specs/2026-10-31-mac-client-design.md) (in Chinese).

### Editor

Requires Node 20+.

```bash
cd editor
npm install
npm run dev     # debug in the browser (loads a sample note when there's no host app)
npm test        # opening and saving a note must not change it (including Obsidian syntax)
npm run build   # outputs to android/app/src/main/assets/editor/
```

### Publishing a new version

On `main`, with everything committed and pushed, run:

```bash
scripts/release.sh
```

The script opens an editor for the update notes (the app shows them in its update prompt; the commits since the last release are listed for reference). After you confirm, it bumps the minor version of `appVersion` in [`android/app/build.gradle.kts`](android/app/build.gradle.kts) (e.g. `0.2.0 → 0.3.0`), commits, tags, pushes, and waits while GitHub Actions tests, signs and publishes the APK and the Mac app under [Releases](https://github.com/leon-mason/jitnote/releases).

- `scripts/release.sh -n` previews the version and commits without changing anything; `-m "notes"` gives the notes directly; `-y` skips the confirmation.
- **Bumping the major version**: raise `MAJOR` at the top of `scripts/release.sh` (e.g. to `2`) and commit. The next release is `2.0.0`, then `2.1.0`, `2.2.0`, …
- The script refuses to release when not on `main`, with uncommitted changes, when out of sync with GitHub, with no commits since the last release, or when `editor/` changed without a fresh `npm run build`.

The release signing key is kept in the repository secrets (`RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`). **Always sign with the same key**: an APK signed with a different key can't update an installed app.

### Local test server for debug builds

Debug builds allow cleartext HTTP to the emulator host `10.0.2.2` (see `android/app/src/debug/`), so you can run end-to-end tests against a local `git http-backend`. Release builds are not affected.

## Contributing

Issues and pull requests are welcome. Before changing the sync logic or the editor, please read [docs/design.md](docs/design.md). A few rules are firm: no Git jargon in the UI, never force-push, and opening then saving a note must not change it. The related tests must keep passing.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Git is a registered trademark of Software Freedom Conservancy. "记特 / Jitnote" only borrows its sound; this project is not affiliated with the Git project.

Main third-party components and their licenses: [JGit](https://www.eclipse.org/jgit/) (EDL 1.0), [Milkdown](https://milkdown.dev/) (MIT), [DOMPurify](https://github.com/cure53/DOMPurify) (Apache 2.0 / MPL 2.0), AndroidX / Jetpack Compose (Apache 2.0).
