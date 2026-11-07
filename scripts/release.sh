#!/usr/bin/env bash
#
# 发布一个新版本：算出新版本号 → 改 appVersion → 提交 → 打带更新说明的标签 → 推送。
# 推送标签后，GitHub Actions（.github/workflows/release.yml）会测试、签名并发布安装包，
# 已安装的 App 会提示更新。
# 运行过 scripts/setup-gitee-mirror.sh 的电脑，还会把提交和标签推到 Gitee 镜像；推不上去只提示，不影响发版。
#
# 用法：
#   scripts/release.sh                 打开编辑器写更新说明
#   scripts/release.sh -m "更新说明"     直接给出更新说明
#   scripts/release.sh -F notes.txt    从文件读取更新说明
#   scripts/release.sh -n              只预览，不做任何改动
#   scripts/release.sh -y              不再询问确认
#
# 版本号规则：每次发版小版本号加一（0.2.0 → 0.3.0）。
# 要升级大版本时，把下面的 MAJOR 改大（比如改成 2）并提交，下次发版就是 2.0.0，之后 2.1.0、2.2.0……

MAJOR=0

set -euo pipefail

GRADLE_FILE="android/app/build.gradle.kts"
REPO="leon-mason/jitnote"

die() { echo "✗ $*" >&2; exit 1; }

notes=""
notes_file=""
dry_run=false
assume_yes=false
while getopts "m:F:nyh" opt; do
    case "$opt" in
        m) notes="$OPTARG" ;;
        F) notes_file="$OPTARG" ;;
        n) dry_run=true ;;
        y) assume_yes=true ;;
        h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) exit 1 ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

# ---------------------------------------------------------------- 发版前检查

[ "$(git branch --show-current)" = "main" ] || die "请在 main 分支上发版。"
git diff --quiet && git diff --cached --quiet || die "还有没提交的改动，请先提交或撤销。"

git fetch --quiet --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
    die "本地 main 和 GitHub 上的不一致，请先 git pull 或 git push。"

current=$(sed -n 's/^val appVersion = "\(.*\)"$/\1/p' "$GRADLE_FILE")
echo "$current" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "读不出 $GRADLE_FILE 里的 appVersion。"
IFS=. read -r cur_major cur_minor _ <<< "$current"

if [ "$MAJOR" -lt "$cur_major" ]; then
    die "MAJOR=$MAJOR 比当前版本 $current 的大版本号还小，请检查 $0 里的 MAJOR。"
elif [ "$MAJOR" -gt "$cur_major" ]; then
    next="$MAJOR.0.0"
else
    next="$cur_major.$((cur_minor + 1)).0"
fi
tag="v$next"

git rev-parse -q --verify "refs/tags/$tag" > /dev/null && die "标签 $tag 已经存在。"

last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2> /dev/null || true)
range="${last_tag:+$last_tag..}HEAD"
changes=$(git log --no-merges --format='  - %s' "$range")
[ -n "$changes" ] || die "上次发版（${last_tag}）之后没有新的提交。"

# 编辑器打包后的文件是提交在 Android 里的，改了 editor/ 却没重新打包，App 里还是旧的编辑器。
if [ -n "$last_tag" ] &&
    ! git diff --quiet "$last_tag" HEAD -- editor/src editor/index.html &&
    git diff --quiet "$last_tag" HEAD -- android/app/src/main/assets/editor; then
    die "editor/ 改过，但 android/app/src/main/assets/editor/ 没有更新。请在 editor/ 里运行 npm run build 并提交。"
fi

# ---------------------------------------------------------------- 更新说明

if [ -n "$notes_file" ]; then
    [ -f "$notes_file" ] || die "找不到文件 $notes_file"
    notes=$(cat "$notes_file")
elif [ -z "$notes" ] && ! $dry_run; then
    draft=$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")
    trap 'rm -f "$draft"' EXIT
    {
        echo
        echo "# 写下 $tag 的更新内容，用户会在 App 的更新提示里看到。以 # 开头的行会被忽略。"
        echo "# 建议每条一行，以「· 」开头，用大白话写用户能感受到的变化。"
        echo "#"
        echo "# ${last_tag:-第一个版本} 之后的提交："
        echo "$changes" | sed 's/^/#/'
    } > "$draft"
    ${VISUAL:-${EDITOR:-vi}} "$draft"
    notes=$(grep -v '^#' "$draft" || true)
fi
# 去掉开头的空行（结尾的空行 $(...) 会自动去掉）
notes=$(printf '%s\n' "$notes" | sed '/./,$!d')
$dry_run || [ -n "$notes" ] || die "更新说明是空的，已取消。"

# ---------------------------------------------------------------- 确认并发布

echo
echo "版本：$current → ${next}（标签 ${tag}）"
echo "${last_tag:-第一个版本} 之后的提交："
echo "$changes"
echo
echo "更新说明："
if [ -n "$notes" ]; then printf '%s\n' "$notes" | sed 's/^/  /'; else echo "  （发版时再写）"; fi
echo

if $dry_run; then
    echo "这是预览（-n），没有做任何改动。"
    exit 0
fi

if ! $assume_yes; then
    printf "确认发布 %s 吗？[y/N] " "$tag"
    read -r answer
    case "$answer" in y | Y | yes) ;; *) die "已取消。" ;; esac
fi

perl -pi -e "s/^val appVersion = \".*\"\$/val appVersion = \"$next\"/" "$GRADLE_FILE"
git commit --quiet -m "Release $next" -- "$GRADLE_FILE"
printf '%s\n' "$notes" | git tag --annotate --cleanup=whitespace --file=- "$tag"
# 一起推送：要么都成功，要么都不推，不会出现有提交没标签的情况。
# 直接推到 GitHub 的地址，而不是 origin：origin 可能还配了 Gitee 镜像，Gitee 失败不能让发版半途退出，
# 那时 GitHub 上已经有了标签、开始打包，再运行本脚本会因为“标签已经存在”被拒绝。
git push --quiet --atomic "$(git remote get-url origin)" main "$tag"
git fetch --quiet origin main
echo "✓ 已推送 ${tag}，GitHub 正在打包发布。"
for mirror in $(git remote get-url --push --all origin | grep -v github.com || true); do
    git push --quiet --atomic "$mirror" main "$tag" ||
        echo "! 没能推到镜像 $mirror，GitHub 上的发布不受影响。之后运行 git push --follow-tags 补上。"
done

if command -v gh > /dev/null; then
    run=""
    for _ in 1 2 3 4 5 6; do
        sleep 5
        run=$(gh run list --repo "$REPO" --workflow release.yml --branch "$tag" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
        [ -n "$run" ] && break
    done
    if [ -n "$run" ]; then
        echo "  等待打包完成（大约 5 分钟）…"
        gh run watch "$run" --repo "$REPO" --exit-status --interval 15 > /dev/null ||
            die "发布没有成功，请看 https://github.com/$REPO/actions/runs/$run"
        echo "✓ 发布完成：https://github.com/$REPO/releases/tag/$tag"
        exit 0
    fi
fi
echo "发布进度：https://github.com/$REPO/actions"
