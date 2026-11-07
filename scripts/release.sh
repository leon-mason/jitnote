#!/usr/bin/env bash
#
# 发布一个新版本：算出新版本号 → 改 appVersion → 提交 → 打带更新说明的标签 → 推送 →
# 等 GitHub Actions（.github/workflows/release.yml）测试、签名、打包成 GitHub 上的草稿发行版 →
# 把安装包传到 Gitee 发行版 → 生成 latest.json 传到两边 → 公开 GitHub 上的发行版 →
# 删掉 Gitee 上最近 5 个以外的旧发行版。公开以后，已安装的 App 才会提示更新。
# 连 Gitee 的事都在这台电脑上做，因为 GitHub 的服务器连 gitee.com 很不稳定。
# 任何一个安装包没传上去，整次停下：GitHub 上留着草稿，Gitee 上这次建的发行版删掉，哪边都不提示新版本。
# 修好后用 -p 从“传 Gitee”这一步重新来。
#
# 用法：
#   scripts/release.sh                 打开编辑器写更新说明
#   scripts/release.sh -m "更新说明"     直接给出更新说明
#   scripts/release.sh -F notes.txt    从文件读取更新说明
#   scripts/release.sh -n              只预览，并检查发布要用的工具和令牌，不做任何改动
#   scripts/release.sh -y              不再询问确认
#   scripts/release.sh -p v0.11.0      GitHub 上的草稿打包好以后，只做后面的发布步骤（上次中途失败时用）
#
# 需要：gh 已登录 GitHub；这台电脑能用 SSH 推到 Gitee（运行过 scripts/setup-gitee-mirror.sh）；
# 登录钥匙串里有 Gitee 私人令牌（勾选 projects），存法见下面 GITEE_KEYCHAIN 处的报错提示。
# 会改动：appVersion、新提交和标签（推到 GitHub 和 Gitee）、GitHub 和 Gitee 上的发行版。
#
# 版本号规则：每次发版小版本号加一（0.2.0 → 0.3.0）。
# 要升级大版本时，把下面的 MAJOR 改大（比如改成 2）并提交，下次发版就是 2.0.0，之后 2.1.0、2.2.0……

MAJOR=0

set -euo pipefail

GRADLE_FILE="android/app/build.gradle.kts"
# 两个环境变量只用来拿临时测试仓库试发布步骤，正常发版不要设。
REPO="${JITNOTE_GITHUB_REPO:-leon-mason/jitnote}"
GITEE_REPO="${JITNOTE_GITEE_REPO:-shitoupapa/jitnote}"
GITEE_GIT="git@gitee.com:$GITEE_REPO.git"
GITEE_API="https://gitee.com/api/v5/repos/$GITEE_REPO"
GITEE_KEYCHAIN="jitnote-release-gitee"
# Gitee 每个仓库的附件总共只能放 1G，每个版本约 106MB，所以只留最近 5 个发行版（设计说明「检查更新」）。
GITEE_KEEP=5
# Gitee 单个附件的上限，2026-11-07 实测正好 100 MiB，多 1 字节就被拒。
GITEE_MAX_SIZE=104857600

die() { echo "✗ $*" >&2; exit 1; }

notes=""
notes_file=""
dry_run=false
assume_yes=false
publish_tag=""
while getopts "m:F:nyp:h" opt; do
    case "$opt" in
        m) notes="$OPTARG" ;;
        F) notes_file="$OPTARG" ;;
        n) dry_run=true ;;
        y) assume_yes=true ;;
        p) publish_tag="$OPTARG" ;;
        h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) exit 1 ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

# ---------------------------------------------------------------- 发布到 GitHub 和 Gitee

gitee_token=""

# 调 Gitee 接口：gitee 方法 路径 [curl 参数…]，成功时输出返回的内容。
# 令牌从标准输入交给 curl，不出现在命令行参数里，别的程序用 ps 看不到。
gitee() {
    local method=$1 path=$2 out status
    shift 2
    out=$(printf 'header = "Authorization: token %s"\n' "$gitee_token" |
        curl -sS -K - -X "$method" --connect-timeout 20 --max-time 900 -w '\n%{http_code}' "$@" "$GITEE_API$path") ||
        return 1
    status=${out##*$'\n'}
    out=${out%$'\n'*}
    case "$status" in
        2??) printf '%s' "$out" ;;
        *) echo "  Gitee 返回 ${status}：$out" >&2; return 1 ;;
    esac
}

# 打标签之前就把发布要用的东西查一遍，不要等 GitHub 打包完、版本号已经用掉才发现。
check_publish_tools() {
    command -v gh > /dev/null || die "需要 GitHub 命令行工具：brew install gh，然后 gh auth login。"
    gh auth status --hostname github.com > /dev/null 2>&1 || die "gh 还没登录 GitHub，请先运行 gh auth login。"
    command -v jq > /dev/null || die "需要 jq：brew install jq。"
    gitee_token=$(security find-generic-password -s "$GITEE_KEYCHAIN" -w 2> /dev/null) ||
        die "钥匙串里没有 Gitee 令牌。在 https://gitee.com/profile/personal_access_tokens 生成一个私人令牌（勾选 projects），再运行下面这条，按提示粘贴：
  security add-generic-password -U -a shitoupapa -s $GITEE_KEYCHAIN -w"
    local can_push
    can_push=$(gitee GET "" | jq -r '.permission.push // false') ||
        die "用钥匙串里的令牌访问不了 Gitee 仓库 ${GITEE_REPO}（原因见上一行）。令牌过期或删掉了的话，重新生成并存一次。"
    [ "$can_push" = true ] || die "钥匙串里的 Gitee 令牌对 $GITEE_REPO 没有写权限。"
    git ls-remote --exit-code "$GITEE_GIT" HEAD > /dev/null 2>&1 ||
        die "这台电脑没法用 SSH 连上 ${GITEE_GIT}。请先运行 scripts/setup-gitee-mirror.sh。"
}

publish_dir=""
gitee_release=""
published=false
github_draft=true
publish_exit() {
    local status=$1
    # Gitee 没有草稿，发行版一建好就是“最新”。半途停下时不删掉，新版 App 在 Gitee 那边会一直拿不到 latest.json。
    if [ "$status" != 0 ] && [ -n "$gitee_release" ] && ! $published; then
        echo "  正在删掉 Gitee 上这次建的发行版…" >&2
        gitee DELETE "/releases/$gitee_release" > /dev/null ||
            echo "! 没删掉，请到 https://gitee.com/$GITEE_REPO/releases 手动删掉 ${publish_tag}。" >&2
    fi
    [ -z "$publish_dir" ] || rm -rf "$publish_dir"
    [ -z "${draft:-}" ] || rm -f "$draft"
    if [ "$status" != 0 ] && $github_draft; then
        echo "✗ 这个版本没有公开，已安装的 App 不会提示它。修好后运行 scripts/release.sh -p $publish_tag 重新发布。" >&2
    fi
}

# GitHub 上的草稿打包好以后：传 Gitee → 两边传 latest.json → 公开 GitHub 发行版 → 清理 Gitee 旧版本。
# 重复运行没关系：Gitee 上同名的发行版会删掉重建，GitHub 上的 latest.json 会覆盖。
publish() {
    publish_tag=$1
    local version=${1#v} info apk dmg exe name size
    git rev-parse -q --verify "refs/tags/$publish_tag" > /dev/null || git fetch --quiet origin "refs/tags/$publish_tag:refs/tags/$publish_tag" 2> /dev/null ||
        die "本地和 GitHub 上都没有标签 ${publish_tag}。"
    publish_dir=$(mktemp -d "${TMPDIR:-/tmp}/jitnote-release.XXXXXX")
    trap 'publish_exit $?' EXIT

    info=$(gh release view "$publish_tag" --repo "$REPO" --json isDraft,body,assets) ||
        die "GitHub 上没有 $publish_tag 的发行版，打包可能还没完成。"
    [ "$(jq -r '.isDraft' <<< "$info")" = true ] || github_draft=false
    apk="jitnote-$version.apk"
    dmg="Jitnote-mac-apple-silicon-$version.dmg"
    exe="Jitnote-windows-x64-$version.exe"
    # 只传 App 自动更新要用的三个包。Windows 的 zip 只给 0.7.0、0.8.0 检查更新用，它们只认 GitHub。
    for name in "$apk" "$dmg" "$exe"; do
        jq -e --arg n "$name" '.assets | any(.name == $n)' <<< "$info" > /dev/null ||
            die "GitHub 上的 $publish_tag 缺少 ${name}，打包可能没有成功。"
    done
    jq -r '.body' <<< "$info" | perl -0pe 's/\s+\z//' > "$publish_dir/notes.md"

    echo "  从 GitHub 下载安装包…"
    gh release download "$publish_tag" --repo "$REPO" --dir "$publish_dir" --pattern "$apk" --pattern "$dmg" --pattern "$exe"
    for name in "$apk" "$dmg" "$exe"; do
        size=$(stat -f %z "$publish_dir/$name")
        [ "$size" = "$(jq --arg n "$name" '.assets[] | select(.name == $n) | .size' <<< "$info")" ] ||
            die "下载的 $name 和 GitHub 上的大小不一样，请重试。"
        [ "$size" -le "$GITEE_MAX_SIZE" ] ||
            die "$name 有 $size 字节，超过了 Gitee 单个附件 100 MiB 的上限，传不上去。要先把它变小。"
    done

    # Gitee 上建发行版要用到标签。镜像推送失败只是提示，所以这里再推一次；已经推过的话什么也不做。
    local pushed
    pushed=$(git push --quiet "$GITEE_GIT" "refs/tags/$publish_tag" 2>&1) ||
        die "没能把标签 $publish_tag 推到 Gitee：$pushed"

    local releases old
    releases=$(gitee GET "/releases?per_page=100") || die "没能列出 Gitee 上的发行版。"
    # Gitee 把最后建的发行版当成“最新”，补发旧版本会让 App 在 Gitee 那边看到旧版本。
    local newest
    newest=$({ jq -r '.[].tag_name' <<< "$releases"; echo "$publish_tag"; } | sort -V | tail -n 1)
    [ "$newest" = "$publish_tag" ] ||
        die "Gitee 上已经有更新的 ${newest}，再发布 $publish_tag 会让它在 Gitee 上变成最新，已取消。"
    for old in $(jq -r --arg t "$publish_tag" '.[] | select(.tag_name == $t) | .id' <<< "$releases"); do
        echo "  删掉 Gitee 上次没发完的 ${publish_tag}…"
        gitee DELETE "/releases/$old" > /dev/null || die "没能删掉 Gitee 上已有的 $publish_tag 发行版。"
    done

    echo "  在 Gitee 上建发行版并上传安装包…"
    # 只建正式版：Gitee 把预发布也当成“最新”。
    gitee_release=$(gitee POST "/releases" --data-urlencode "tag_name=$publish_tag" --data-urlencode "name=$version" \
        --data-urlencode "body@$publish_dir/notes.md" --data-urlencode "target_commitish=main" --data "prerelease=false" |
        jq -r '.id') || die "没能在 Gitee 上建发行版。"
    [ -n "$gitee_release" ] && [ "$gitee_release" != null ] || die "Gitee 建发行版没有返回编号。"
    for name in "$apk" "$dmg" "$exe"; do
        size=$(gitee POST "/releases/$gitee_release/attach_files" -F "file=@$publish_dir/$name" | jq -r '.size') ||
            die "$name 没能传到 Gitee。"
        [ "$size" = "$(stat -f %z "$publish_dir/$name")" ] || die "Gitee 上的 $name 大小不对（$size 字节）。"
        echo "    ✓ $name"
    done

    package() {
        jq -n --arg name "$1" --argjson size "$(stat -f %z "$publish_dir/$1")" \
            --arg sha256 "$(shasum -a 256 "$publish_dir/$1" | cut -d ' ' -f 1)" \
            --arg gitee "https://gitee.com/$GITEE_REPO/releases/download/$publish_tag/$1" \
            --arg github "https://github.com/$REPO/releases/download/$publish_tag/$1" \
            '{name: $name, size: $size, sha256: $sha256, gitee: $gitee, github: $github}'
    }
    jq -n --arg version "$version" --rawfile notes "$publish_dir/notes.md" \
        --argjson android "$(package "$apk")" --argjson mac "$(package "$dmg")" --argjson windows "$(package "$exe")" \
        '{format: 1, version: $version, notes: $notes,
          packages: {"android": $android, "mac-apple-silicon": $mac, "windows-x64": $windows}}' > "$publish_dir/latest.json"

    # latest.json 最后上传：App 看到它时，里面列的安装包两边都已经能下载。
    echo "  上传 latest.json…"
    gh release upload "$publish_tag" "$publish_dir/latest.json" --repo "$REPO" --clobber
    gitee POST "/releases/$gitee_release/attach_files" -F "file=@$publish_dir/latest.json" > /dev/null ||
        die "latest.json 没能传到 Gitee。"

    if $github_draft; then
        gh release edit "$publish_tag" --repo "$REPO" --draft=false > /dev/null
    fi
    published=true
    echo "✓ 已公开：https://github.com/$REPO/releases/tag/$publish_tag"
    echo "  Gitee：https://gitee.com/$GITEE_REPO/releases/tag/$publish_tag"

    # 删整个发行版而不是只删附件：不留下载不了的空发行版。删发行版不会删 Gitee 上的标签。
    local id
    releases=$(gitee GET "/releases?per_page=100") || {
        echo "! 没能列出 Gitee 上的发行版，这次没清理旧版本，不影响发布。"
        return 0
    }
    for id in $(jq -r '[.[] | {id, v: (.tag_name | ltrimstr("v") | split(".") | map(tonumber? // 0))}]
        | sort_by(.v) | reverse | .['"$GITEE_KEEP"':][] | .id' <<< "$releases"); do
        gitee DELETE "/releases/$id" > /dev/null ||
            echo "! 没能删掉 Gitee 上的旧发行版（编号 ${id}），不影响这次发布，下次发版会再删。"
    done
}

if [ -n "$publish_tag" ]; then
    echo "$publish_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "-p 后面要跟版本标签，例如 v0.11.0。"
    check_publish_tools
    publish "$publish_tag"
    exit 0
fi

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

check_publish_tools

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
echo "✓ 已推送 ${tag}，GitHub 正在打包。"
for mirror in $(git remote get-url --push --all origin | grep -v github.com || true); do
    git push --quiet --atomic "$mirror" main "$tag" ||
        echo "! 没能推到镜像 ${mirror}，GitHub 上的发布不受影响。之后运行 git push --follow-tags 补上。"
done

run=""
for _ in 1 2 3 4 5 6; do
    sleep 5
    run=$(gh run list --repo "$REPO" --workflow release.yml --branch "$tag" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
    [ -n "$run" ] && break
done
[ -n "$run" ] || die "没找到 $tag 的打包任务，请看 https://github.com/$REPO/actions 。打包完成后运行 scripts/release.sh -p $tag 继续发布。"
echo "  等待打包完成（大约 5 分钟）…"
gh run watch "$run" --repo "$REPO" --exit-status --interval 15 > /dev/null ||
    die "打包没有成功，请看 https://github.com/$REPO/actions/runs/$run 。GitHub 上只有草稿，App 不会提示这个版本。修好并重新打包后运行 scripts/release.sh -p $tag 继续发布。"
echo "✓ 打包完成，开始发布到 GitHub 和 Gitee。"
publish "$tag"
