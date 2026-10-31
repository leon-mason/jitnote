# Git Notebook (git-notebook)

[简体中文](README.md) | English

A notes app for your phone that keeps your notes in **your own** private GitHub / Gitee repositories. Fully open source, no server, no data collection.

- **Every notebook is a real Git repository**: the phone keeps a full `.git` with real commit history. Clone it on your computer, edit with any editor or AI tool (Cursor, Claude Code, …), push, and tap sync on the phone to get the changes.
- **Just one "Sync" button**: notes are saved and versioned automatically. Sync = commit → fetch → merge → push. Never force-pushes.
- **Conflicts never lose data**: if the same note was edited in two places, the newer version is kept. The other version stays in history and can be restored with one tap.
- **WYSIWYG**: you see an ordinary note (headings, bold, lists, to-dos, tables). What's saved is standard Markdown that Obsidian / Typora can open directly.
- **Works with existing repositories**: use your Obsidian or Typora notes repository as-is. Existing files and image references are left untouched.

> **Status**: early version. Only the Android client exists so far, and the UI is Chinese only. Feedback is welcome; please keep a backup of important notes on your computer.

## Repository layout

| Directory | Contents |
| --- | --- |
| [`android/`](android/) | Android client (Kotlin + Jetpack Compose + [JGit](https://www.eclipse.org/jgit/)) |
| [`editor/`](editor/) | Note editor shared by all clients ([Milkdown](https://milkdown.dev/) Crepe, bundled as an offline web page embedded in the app) |
| [`docs/`](docs/) | Design notes (in Chinese) |

Future iOS and desktop clients will live in this repository too, reuse `editor/`, and follow the same sync rules (see [docs/design.md](docs/design.md)).

## Usage (Android)

Requires Android 8.0 or later. Download the latest `git-notebook-x.y.z.apk` from [Releases](https://github.com/leon-mason/git-notebook/releases/latest) and install it.

1. Open the app, tap "连接云端账号" (Connect cloud account), follow the on-screen steps to create a token on Gitee or GitHub, and paste it in.
2. Tap "添加笔记本 → 新建" (Add notebook → New) and give it a name. The app creates a **private** repository in your account.
3. Write notes. They're saved automatically when you leave a note; tap the sync button in the top-right corner to upload them.
4. Already have a notes repository (e.g. from Obsidian)? Pick it under "添加笔记本 → 用已有的" (Add notebook → Use existing). Existing files are kept as they are.
5. New or second phone: connect the same account, then pick your notebooks under "用已有的" (Use existing).

The home screen lists **every note** in the current notebook (no folders), sorted by modified time or title. Swipe right anywhere on the screen, or tap ☰ in the top-left corner, to open the folder tree; tap a folder to see only its notes. Tap the notebook name at the top to switch notebooks or open "管理笔记本" (Manage notebooks).

Deleting a notebook only removes the copy on the phone; the repository in the cloud is not affected.

When a new version is out, the app offers to update when you open it (it checks at most once a day). You can also check by hand from the home screen's "⋮ → 检查更新" (Check for updates).

### Tokens and privacy

- Required token permissions: for a Gitee personal token, keep the default selection (at least `user_info` and `projects`); for a GitHub classic token, select `repo`.
- These permissions grant read/write access to **all** repositories in your account. Only use the token on your own phone, and delete it in your Gitee / GitHub settings whenever you no longer need it.
- The token is encrypted with the Android Keystore and stored only on the phone. System backup is disabled for the app.
- The app only talks to your own Gitee / GitHub account. The one exception is the update check: at most once a day, it asks this project's GitHub page anonymously whether there is a new version. No token and no note content is sent. There are no analytics or ads.

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

The script opens an editor for the update notes (the app shows them in its update prompt; the commits since the last release are listed for reference). After you confirm, it bumps the minor version of `appVersion` in [`android/app/build.gradle.kts`](android/app/build.gradle.kts) (e.g. `0.2.0 → 0.3.0`), commits, tags, pushes, and waits while GitHub Actions tests, signs and publishes the APK under [Releases](https://github.com/leon-mason/git-notebook/releases).

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

Main third-party components and their licenses: [JGit](https://www.eclipse.org/jgit/) (EDL 1.0), [Milkdown](https://milkdown.dev/) (MIT), [DOMPurify](https://github.com/cure53/DOMPurify) (Apache 2.0 / MPL 2.0), AndroidX / Jetpack Compose (Apache 2.0).
