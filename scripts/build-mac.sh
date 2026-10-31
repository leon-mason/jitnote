#!/usr/bin/env bash
#
# 不用 Xcode 构建 Mac 版：直接调用 swiftc，Git 用 Homebrew 的 libgit2（brew install libgit2）。
#
#   scripts/build-mac.sh          → mac/build/GitNotebook.app 和 mac/build/GitNotebook-mac-<版本>.zip
#   scripts/build-mac.sh --test   → 编译并运行测试
#   scripts/build-mac.sh --run    → 构建后直接打开
#   scripts/build-mac.sh --debug  → 带测试用遥控（见 mac/Sources/UI/DebugHooks.swift）的版本，不打 zip
#
# 编辑器用的是 android/app/src/main/assets/editor/（editor/ 的构建产物），和 Android 完全相同。

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
MAC=mac
BUILD="$MAC/build"
APP="$BUILD/GitNotebook.app"
VERSION=$(sed -n 's/^val appVersion = "\(.*\)"$/\1/p' android/app/build.gradle.kts)
IFS=. read -r major minor patch <<< "$VERSION"
BUILD_NUMBER=$((major * 10000 + minor * 100 + patch))

die() { echo "✗ $*" >&2; exit 1; }

command -v brew > /dev/null || die "需要 Homebrew：https://brew.sh"
GIT2=$(brew --prefix libgit2)
[ -f "$GIT2/include/git2.h" ] || die "需要 libgit2：brew install libgit2"

# The app can't run on an older macOS than the libgit2 it bundles was built for; say so in the app.
MIN_MACOS=$(otool -l "$GIT2/lib/libgit2.dylib" | awk '/minos/ { print $2; exit }')
[ "$(printf '%s\n14.0\n' "$MIN_MACOS" | sort -V | head -1)" = "14.0" ] || MIN_MACOS=14.0
TARGET="arm64-apple-macos$MIN_MACOS"

# 命令行工具里可能同时有好几个 SDK，最新的不一定和编译器配套；挑第一个能用的。
pick_sdk() {
    local probe="$BUILD/.sdk-probe.swift"
    echo 'import Foundation' > "$probe"
    local sdk
    for sdk in "${SDKROOT:-}" "$(xcrun --show-sdk-path --sdk macosx 2> /dev/null)" $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.*.sdk 2> /dev/null | sort -rV); do
        [ -n "$sdk" ] && [ -d "$sdk" ] || continue
        if swiftc -sdk "$sdk" -target "$TARGET" -typecheck "$probe" 2> /dev/null; then
            echo "$sdk"
            return
        fi
    done
    die "找不到和 Swift 编译器配套的 macOS SDK"
}

mkdir -p "$BUILD"
SDK=$(pick_sdk)
SWIFT_FLAGS=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -I "$MAC/CGit2" -Xcc "-I$GIT2/include" -L "$GIT2/lib")

if [ "${1:-}" = "--test" ]; then
    swiftc "${SWIFT_FLAGS[@]}" -Xlinker -rpath -Xlinker "$GIT2/lib" \
        "$MAC"/Sources/Core/*.swift "$MAC"/Sources/Data/*.swift "$MAC"/Tests/*.swift -o "$BUILD/GitNotebookTests"
    exec "$BUILD/GitNotebookTests"
fi

echo "编译 Git 笔记本 $VERSION …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
EXTRA=()
[ "${1:-}" = "--debug" ] && EXTRA=(-D GN_DEBUG_HOOKS)
swiftc "${SWIFT_FLAGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} -O -parse-as-library \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$MAC"/Sources/Core/*.swift "$MAC"/Sources/Data/*.swift "$MAC"/Sources/UI/*.swift \
    -o "$APP/Contents/MacOS/GitNotebook"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__MIN_MACOS__/$MIN_MACOS/" \
    "$MAC/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp -R android/app/src/main/assets/editor "$APP/Contents/Resources/editor"
[ -f "$MAC/Resources/AppIcon.icns" ] && cp "$MAC/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# 把 libgit2 和它依赖的 Homebrew 库一起放进 App，用户的 Mac 上不需要装任何东西。
bundle_libs() {
    local binary="$1" dep name
    for dep in $(otool -L "$binary" | awk 'NR > 1 { print $1 }' | grep -E '^(/opt/homebrew|/usr/local)/'); do
        name=$(basename "$dep")
        # The signatures these edits break are redone below.
        install_name_tool -change "$dep" "@rpath/$name" "$binary" 2> /dev/null
        if [ ! -f "$APP/Contents/Frameworks/$name" ]; then
            cp "$dep" "$APP/Contents/Frameworks/$name"
            chmod u+w "$APP/Contents/Frameworks/$name"
            install_name_tool -id "@rpath/$name" "$APP/Contents/Frameworks/$name" 2> /dev/null
            bundle_libs "$APP/Contents/Frameworks/$name"
        fi
    done
}
bundle_libs "$APP/Contents/MacOS/GitNotebook"
# @rpath inside the libraries resolves against the app's rpath, so they find each other in Frameworks.

# 没有苹果开发者账号，只做本机签名（ad-hoc）；首次打开需要右键「打开」。
codesign --force --sign - "$APP"/Contents/Frameworks/*.dylib 2> /dev/null
codesign --force --sign - "$APP" 2> /dev/null

if [ "${1:-}" = "--debug" ]; then
    echo "✓ ${APP}（测试版）"
    exit 0
fi

ZIP="$BUILD/GitNotebook-mac-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $APP"
echo "✓ $ZIP"

[ "${1:-}" = "--run" ] && open "$APP"
exit 0
