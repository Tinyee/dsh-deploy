#!/bin/bash
# ============================================================
# update-dsh.sh — 把 @deepseek-ai/dsh 升级到 npm 最新版，
#                同步 ~/.dsh/runtime 副本，并重启 launchd 服务
#
# 用法:
#   ~/.dsh/update-dsh.sh           # 检查并自动升级（只有发现新版才会动）
#   ~/.dsh/update-dsh.sh --check   # 只检查版本，不升级、不重启
#
# 注意: 升级完成会重启 dsh-web 服务，页面会断几秒，刷新即可。
# ============================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME="$DSH_HOME/runtime"
LABEL="com.user.dsh-web"
LOG="$DSH_HOME/logs/dsh-update.log"
BIN="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
PORT=3080

CHECK_ONLY="${1:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- 1) 当前副本版本 vs npm 最新版本 ---
CURRENT="$(node "$BIN" --version 2>/dev/null || echo unknown)"
LATEST="$(npm view @deepseek-ai/dsh version 2>/dev/null || echo unknown)"

log "当前副本版本: $CURRENT"
log "npm 最新版本: $LATEST"

if [ "$CURRENT" = "$LATEST" ]; then
    log "已是最新版本，无需更新"
    exit 0
fi

if [ "$CHECK_ONLY" = "--check" ]; then
    log "检测到新版本 ${LATEST}（当前 ${CURRENT}），--check 模式跳过升级"
    exit 0
fi

# --- 2) 在 runtime 目录里原地安装最新版 ---
log "开始升级副本: npm install @deepseek-ai/dsh@$LATEST"
(cd "$RUNTIME" && npm install "@deepseek-ai/dsh@$LATEST")

# --- 3) 校验安装结果 ---
NEW="$(node "$BIN" --version 2>/dev/null || echo unknown)"
if [ "$NEW" != "$LATEST" ]; then
    log "!! 升级后版本校验失败（期望 ${LATEST}，实际 $NEW）"
    exit 1
fi
log "副本升级成功: $CURRENT -> $NEW"

# --- 3.5) 重放本地补丁（升级会覆盖 node_modules 里的本地修改）---
# 仅本机存在补丁脚本时才执行；无补丁的机器/CI 静默跳过。
log "重放本地补丁（remote-settings / tailscale-console，如存在）..."
for patch in patch-remote-settings.js patch-tailscale-console.js; do
    if [ -f "$DSH_HOME/$patch" ]; then
        node "$DSH_HOME/$patch" || log "!! $patch 重放失败（代码结构变化？请手动检查）"
    else
        log "跳过 $patch（本机未安装）"
    fi
done

# --- 4) 重启 launchd 服务（页面断几秒，刷新即可）---
log "重启 launchd 服务 $LABEL ..."
launchctl kickstart -k "gui/$(id -u)/$LABEL"

# --- 5) 等待端口恢复 ---
for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" 2>/dev/null || true)"
    case "$code" in
        2*|3*|4*|5*) log "服务已恢复 (HTTP $code)"; exit 0 ;;
    esac
    sleep 1
done
log "!! 服务未在 30 秒内恢复，请检查: launchctl print gui/$(id -u)/$LABEL"
exit 1
