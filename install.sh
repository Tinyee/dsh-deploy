#!/bin/bash
# ============================================================
# install.sh — DeepSeek Harness 一键安装（自动识别平台）
#
# 用法:
#   ./install.sh            # macOS / Linux 一键安装（从零到自启服务）
#   ./install.sh --check    # 只查看状态
#
# Windows 请用 PowerShell 运行:
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap-dsh-windows.ps1
# ============================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
    Darwin)
        exec "$DIR/scripts/bootstrap-dsh-macos.sh" "$@"
        ;;
    Linux)
        exec "$DIR/scripts/bootstrap-dsh-linux.sh" "$@"
        ;;
    *)
        echo "!! 不支持的平台: $(uname -s)"
        echo "   Windows 请用 PowerShell 运行:"
        echo "   powershell -ExecutionPolicy Bypass -File $DIR/scripts/bootstrap-dsh-windows.ps1"
        exit 1
        ;;
esac
