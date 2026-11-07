#!/usr/bin/env bash
#
# 让这台电脑上的 git push 同时推到 GitHub 和 Gitee 镜像（gitee.com/shitoupapa/jitnote）。
# GitHub 的服务器连不上 gitee.com：GitHub Actions 推不过去，Gitee 镜像的 WebHook 也收不到推送通知，
# 所以改由推送代码的这台电脑顺手推一份。
#
# 用法：
#   scripts/setup-gitee-mirror.sh          配置；重复运行没关系
#   scripts/setup-gitee-mirror.sh --undo   恢复成只推 GitHub
#
# 会改动：本仓库 .git/config 里 origin 的推送地址（remote.origin.pushurl）。不改仓库里的任何文件。
# 需要：这台电脑能用 SSH 连上 Gitee 账号 shitoupapa。换电脑后要重新运行一次。

set -euo pipefail

GITEE_URL="git@gitee.com:shitoupapa/jitnote.git"

die() { echo "✗ $*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--undo" ]; then
    git config --unset-all remote.origin.pushurl || true
    echo "✓ 已恢复：git push 只推到 GitHub。"
    exit 0
fi

github_url=$(git remote get-url origin)
case "$github_url" in
    *github.com*) ;;
    *) die "origin 不是 GitHub 上的仓库：$github_url" ;;
esac

# ssh -T 认证成功时也返回 1（Gitee 不提供 shell），所以只看输出。
greeting=$(ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@gitee.com 2>&1 || true)
case "$greeting" in
    *successfully*) ;;
    *) die "这台电脑没法用 SSH 连上 Gitee。把公钥（~/.ssh/*.pub）加到 https://gitee.com/profile/sshkeys 后再运行。Gitee 的回答：$greeting" ;;
esac

# 只要设了任何一个 pushurl，git push 就不再推到 fetch 地址，所以 GitHub 也要写进来，而且写在前面：
# 两处是依次推送的，GitHub 先成功，Gitee 失败时 GitHub 上的代码不受影响。
git config --unset-all remote.origin.pushurl || true
git config --add remote.origin.pushurl "$github_url"
git config --add remote.origin.pushurl "$GITEE_URL"

echo "✓ 已配置：git push 会依次推到"
git remote get-url --push --all origin | sed 's/^/    /'
echo "  Gitee 那一份没推上去时 git push 会报错，GitHub 上的不受影响；之后再 git push --follow-tags 补上。"
