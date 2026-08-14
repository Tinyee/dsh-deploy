#!/bin/bash
# ============================================================
# bootstrap-dsh-macos.sh — macOS 从零安装 DeepSeek Harness
#
# 流程: ① 无 Node 则用 Homebrew 安装 → ② 交给 setup-dsh-service.sh
#        （runtime 副本、launchd 自启服务、每日升级检查 全自动）
#
# 用法: ~/.dsh/bootstrap-dsh-macos.sh [--check]
# 说明: 幂等，可重复跑；--check 只查看状态不修改
# ============================================================
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [1/2] 检查 Node.js ==="
if command -v node >/dev/null 2>&1; then
    echo "Node.js 已安装: $(node --version)"
else
    echo "未检测到 Node.js，尝试用 Homebrew 安装 ..."
    if ! command -v brew >/dev/null 2>&1; then
        echo "!! 也未检测到 Homebrew。请先安装 Homebrew："
        echo '   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        echo "   然后重新运行本脚本。"
        exit 1
    fi
    brew install node
    echo "Node.js 安装完成: $(node --version)"
fi

echo ""
echo "=== [2/2] 配置 dsh 系统服务 ==="
exec "$DIR/setup-dsh-service.sh" "$@"
