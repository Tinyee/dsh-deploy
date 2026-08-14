#!/bin/bash
# ============================================================
# init-repo.sh — 把 ~/.dsh 的部署脚本同步进 dsh-deploy 仓库
#               并初始化 git（本地提交，推送由你完成）
#
# 用法: ./init-repo.sh
# 之后: cd dsh-deploy && git remote add origin <仓库地址> && git push -u origin main
# ============================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 同步 ~/.dsh 脚本到 $DIR/scripts ==="
mkdir -p "$DIR/scripts"
cp -f ~/.dsh/bootstrap-dsh-macos.sh   ~/.dsh/bootstrap-dsh-linux.sh  "$DIR/scripts/"
cp -f ~/.dsh/setup-dsh-service.sh     ~/.dsh/setup-dsh-linux.sh     "$DIR/scripts/"
cp -f ~/.dsh/update-dsh.sh            ~/.dsh/update-dsh-linux.sh    "$DIR/scripts/"
cp -f ~/.dsh/bootstrap-dsh-windows.ps1 ~/.dsh/setup-dsh-windows.ps1 "$DIR/scripts/"
cp -f ~/.dsh/update-dsh-windows.ps1   ~/.dsh/test-windows-locally.ps1 "$DIR/scripts/"
cp -f ~/.dsh/test-linux-locally.sh    "$DIR/scripts/"
ls -1 "$DIR/scripts/"
chmod +x "$DIR"/scripts/*.sh 2>/dev/null || true

echo ""
echo "=== git 初始化 ==="
if [ ! -d "$DIR/.git" ]; then
    git init -b main "$DIR" >/dev/null
fi
git -C "$DIR" add -A
git -C "$DIR" -c user.name="dsh-deploy" -c user.email="dsh-deploy@local" commit -m "dsh 部署脚本 + 三平台真机 CI" >/dev/null 2>&1 || echo "(无新改动可提交)"

echo ""
echo "完成 ✅  下一步："
echo "  1. GitHub 上建一个空仓库"
echo "  2. cd $DIR && git remote add origin <仓库地址>"
echo "  3. git push -u origin main"
echo "  4. Actions 页面查看三平台测试结果"
