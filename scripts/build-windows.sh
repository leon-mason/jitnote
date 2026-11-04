#!/usr/bin/env bash
#
# 在 Mac 或 Linux 上编译 Windows 11 x64 的记特，并可以先跑测试。
# 不改版本号。版本号读 android/app/build.gradle.kts 里的 appVersion，和 Android、Mac 是同一个。
#
#   scripts/build-windows.sh --test
#       编译并运行 windows/ 里的测试（同步、文件夹、更新包选择）。
#   scripts/build-windows.sh
#       打出 windows/build/Jitnote-windows-x64-<版本>.zip。
#       拿到 Windows 11 上解压，运行里面的 Jitnote.exe。
#       程序没有代码签名，系统会提示发布者不明。
#
# 需要 .NET 8 SDK。本机若装在 ~/.dotnet，脚本会自己加上。
# 产物是自包含的，Windows 上不必再装 .NET。不覆盖正在运行的程序：更新时先退出，再用新的文件替换。

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ -x "$HOME/.dotnet/dotnet" ]; then
    export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
    export PATH="$DOTNET_ROOT:$PATH"
fi

die() { echo "✗ $*" >&2; exit 1; }

command -v dotnet >/dev/null || die "需要 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

VERSION=$(sed -n 's/^val appVersion = "\(.*\)"$/\1/p' android/app/build.gradle.kts)
[ -n "$VERSION" ] || die "读不到 android/app/build.gradle.kts 里的 appVersion"

if [ "${1:-}" = "--test" ]; then
    dotnet test windows/Jitnote.sln -c Release --nologo
    exit 0
fi

OUT="windows/build/publish"
rm -rf "$OUT"
dotnet publish windows/src/Jitnote.App/Jitnote.App.csproj \
    -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=false \
    -p:Version="$VERSION" \
    -o "$OUT" --nologo

# UTF-8 BOM so Notepad on Windows shows the Chinese. The file name stays ASCII so the zip does not mangle it.
printf '\xEF\xBB\xBF' > "$OUT/README.txt"
cat >> "$OUT/README.txt" << EOF
这是记特的 Windows 11（64 位）版本 ${VERSION}。

1. 把整个文件夹解压出来，不要只抽出其中一个文件。
2. 双击 Jitnote.exe。
3. 如果系统提示「Windows 已保护你的电脑」或发布者不明：点「更多信息」，再点「仍要运行」。这个程序没有购买代码签名，只有第一次会这样问。
4. 以后有新版本时，先退出记特，再用新解压出来的文件夹替换这一份。记特还开着的时候不要覆盖它。
EOF

ZIP="windows/build/Jitnote-windows-x64-${VERSION}.zip"
rm -f "$ZIP"
ROOT=$(pwd)
(cd "$OUT" && zip -r -q "$ROOT/$ZIP" .)
echo "✓ $ZIP"
