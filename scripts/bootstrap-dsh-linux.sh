#!/bin/bash
# ============================================================
# bootstrap-dsh-linux.sh — Linux 从零安装 DeepSeek Harness
#
# 流程: ① 无 Node 则用系统包管理器安装（apt/dnf/pacman）
#       → ② 交给 setup-dsh-linux.sh（systemd 用户服务 + 每日升级检查）
#
# 用法: ~/.dsh/bootstrap-dsh-linux.sh [--check|--no-timer]
# 说明:
#   - 需要 sudo 权限安装系统包（只会在缺 Node 时触发）
#   - 部分发行版仓库的 Node 版本偏旧，若 dsh 报 engine 版本错误，
#     建议用 nvm 装新版 Node: https://github.com/nvm-sh/nvm
#   - SSH 环境请先 export XDG_RUNTIME_DIR=/run/user/$(id -u)
# ============================================================
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [1/2] 检查 Node.js ==="
if command -v node >/dev/null 2>&1; then
    echo "Node.js 已安装: $(node --version)"
else
    echo "未检测到 Node.js，尝试用系统包管理器安装 ..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y nodejs npm
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y nodejs npm
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm nodejs npm
    else
        echo "!! 未识别的包管理器。请手动安装 Node.js 后重试。"
        exit 1
    fi
    echo "Node.js 安装完成: $(node --version)"
fi

# 版本下限提醒（dsh 需要较新的 Node）
MAJOR="$(node --version | sed 's/^v//; s/\..*//')"
if [ "${MAJOR:-0}" -lt 20 ]; then
    echo "!! 警告：Node 主版本 $MAJOR 偏旧，若 dsh 报 engine 版本错误，请用 nvm 安装新版："
    echo "   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
fi

echo ""
echo "=== [2/2] 配置 dsh systemd 服务 ==="
exec "$DIR/setup-dsh-linux.sh" "$@"
