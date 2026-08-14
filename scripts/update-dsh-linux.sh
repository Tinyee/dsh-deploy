#!/bin/bash
# ============================================================
# update-dsh-linux.sh — Linux 版：升级 @deepseek-ai/dsh 到最新版，
#                      同步 ~/.dsh/runtime 副本并重启 systemd 服务
#
# 用法:
#   ~/.dsh/update-dsh-linux.sh          # 检查并自动升级（有新版才动手）
#   ~/.dsh/update-dsh-linux.sh --check  # 只检查版本，不升级不重启
# ============================================================
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME="$DSH_HOME/runtime"
BIN="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
UNIT="dsh-web.service"
LOG="$DSH_HOME/logs/dsh-update.log"
PORT="${DSH_WEB_PORT:-3080}"
MODE="${1:-}"

mkdir -p "$DSH_HOME/logs"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# --- 1) 当前副本版本 vs npm 最新版本 ---
CURRENT="$(node "$BIN" --version 2>/dev/null || echo unknown)"
LATEST="$(npm view @deepseek-ai/dsh version 2>/dev/null || echo unknown)"

log "当前副本版本: $CURRENT"
log "npm 最新版本: $LATEST"

if [ "$CURRENT" = "$LATEST" ]; then
    log "已是最新版本，无需更新"
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    log "检测到新版本 $LATEST（当前 $CURRENT），--check 模式跳过升级"
    exit 0
fi

# --- 2) 在 runtime 目录里原地安装最新版 ---
log "开始升级副本: npm install @deepseek-ai/dsh@$LATEST"
(cd "$RUNTIME" && npm install "@deepseek-ai/dsh@$LATEST")

# --- 3) 校验安装结果 ---
NEW="$(node "$BIN" --version 2>/dev/null || echo unknown)"
if [ "$NEW" != "$LATEST" ]; then
    log "!! 升级后版本校验失败（期望 $LATEST，实际 $NEW）"
    exit 1
fi
log "副本升级成功: $CURRENT -> $NEW"

# --- 4) 重启 systemd 服务 ---
log "重启 systemd 服务 $UNIT ..."
systemctl --user restart "$UNIT" || { log "!! systemctl 失败（SSH 环境请先 export XDG_RUNTIME_DIR=/run/user/\$(id -u)）"; exit 1; }

# --- 5) 等待端口恢复 ---
for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" 2>/dev/null || true)"
    case "$code" in
        2*|3*|4*|5*) log "服务已恢复 (HTTP $code)"; exit 0 ;;
    esac
    sleep 1
done
log "!! 服务未在 30 秒内恢复，请检查: systemctl --user status $UNIT"
exit 1
