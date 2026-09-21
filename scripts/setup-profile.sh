#!/bin/bash
# ============================================================
# setup-profile.sh — 把 dsh 从"裸官方安装"复现为完整自定义环境:
#
#   ① web profile 自动初始化（首次使用时由 dsh 从随附模板创建）
#   ② 安装 dshmarket 插件市场（幂等: dsh plugin --profile web add dshmarket）
#   ③ settings.yaml 不存在时从 settings.yaml.example 生成（绝不覆盖已有配置）
#   ④ 检测到实际变更时自动重启 dsh-web 服务并等待端口恢复
#
# 用法:
#   ~/.dsh/setup-profile.sh           # 执行（幂等，可重复跑）
#   ~/.dsh/setup-profile.sh --check   # 只报告状态，不改动任何东西
#   ~/.dsh/setup-profile.sh --no-restart  # 有变更时不重启服务（稍后手动重启）
#
# 环境变量: DSH_HOME 覆盖配置目录（默认 ~/.dsh）
#           DSH_WEB_PORT 覆盖检查端口（默认 3080）
# ============================================================
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME="$DSH_HOME/runtime"
TOOLS="$DSH_HOME/tools"
BIN="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
MARKET="dshmarket"
PORT="${DSH_WEB_PORT:-3080}"
MODE="${1:-}"
NO_RESTART=false
if [ "$MODE" = "--no-restart" ]; then MODE=""; NO_RESTART=true; fi
if [ "${2:-}" = "--no-restart" ]; then NO_RESTART=true; fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "!! $*"; exit 1; }

# ---------- 1) 定位 node ----------
NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -z "$NODE_BIN" ] && die "找不到 node，请先安装 Node.js"

# ---------- 2) 确保 runtime 副本存在 ----------
if [ ! -f "$BIN" ]; then
    log "runtime 副本缺失，尝试从 npx 缓存复制 ..."
    SRC=""
    for d in "$HOME"/.npm/_npx/*/; do
        [ -f "$d/node_modules/@deepseek-ai/dsh/lib/bin.js" ] && SRC="$d"
    done
    if [ -n "$SRC" ]; then
        log "从 $SRC 复制到 $RUNTIME"
        mkdir -p "$RUNTIME"
        cp -R "$SRC/." "$RUNTIME/"
    else
        log "npx 缓存也没有，直接从 npm 安装到 ${RUNTIME}（需要网络）"
        mkdir -p "$RUNTIME"
        (cd "$RUNTIME" && npm install @deepseek-ai/dsh)
    fi
    [ -f "$BIN" ] || die "runtime 副本准备失败"
fi
VERSION="$("$NODE_BIN" "$BIN" --version 2>/dev/null || echo unknown)"

# ---------- 3) 评估当前状态（只读，不产生任何变更）----------
PROFILE_JSON="$DSH_HOME/profiles/web/package.json"
SETTINGS="$DSH_HOME/settings.yaml"
PNPM_BIN="$TOOLS/node_modules/.bin/pnpm"

[ -f "$PROFILE_JSON" ] && grep -q '"dshmarket"' "$PROFILE_JSON" 2>/dev/null && MARKET_OK=true || MARKET_OK=false
[ -f "$SETTINGS" ] && SETTINGS_OK=true || SETTINGS_OK=false
[ -x "$PNPM_BIN" ] && PNPM_OK=true || PNPM_OK=false

# ---------- 4) --check 模式：只报告 ----------
if [ "$MODE" = "--check" ]; then
    echo "runtime    : $RUNTIME (v$VERSION)"
    echo "profile    : $PROFILE_JSON [$([ -f "$PROFILE_JSON" ] && echo 存在 || echo 缺失)]"
    echo "dshmarket  : [$($MARKET_OK && echo 已安装 || echo 未安装)]"
    echo "settings   : $SETTINGS [$($SETTINGS_OK && echo 存在 || echo 缺失)]"
    echo "pnpm       : $($PNPM_OK && echo 就绪 || echo "缺失（将由本脚本安装到 $TOOLS）")"
    exit 0
fi

CHANGED=false

# ---------- 5) 确保 pnpm 可用（dsh plugin 依赖它）----------
if $PNPM_OK; then
    log "pnpm 就绪: $PNPM_BIN"
else
    log "未找到 pnpm，安装到 $TOOLS ..."
    mkdir -p "$TOOLS"
    (cd "$TOOLS" && npm install pnpm)
    [ -x "$PNPM_BIN" ] || die "pnpm 安装失败"
    export PATH="$TOOLS/node_modules/.bin:$PATH"
fi

# ---------- 6) 安装/确认 dshmarket（幂等）----------
if $MARKET_OK; then
    log "profile web 已包含 $MARKET，跳过安装"
else
    log "profile web 缺少 $MARKET，执行: dsh plugin --profile web add $MARKET"
    export PATH="$TOOLS/node_modules/.bin:$PATH"
    "$NODE_BIN" "$BIN" plugin --profile web add "$MARKET" || die "安装 $MARKET 失败"
    CHANGED=true
fi

# ---------- 7) settings.yaml：仅首次写入，绝不覆盖 ----------
if $SETTINGS_OK; then
    log "settings.yaml 已存在，保留不动（如需更新请手动编辑）"
else
    EXAMPLE=""
    for cand in "$(dirname "$0")/settings.yaml.example" "$DSH_HOME/settings.yaml.example"; do
        [ -f "$cand" ] && EXAMPLE="$cand" && break
    done
    if [ -n "$EXAMPLE" ]; then
        cp "$EXAMPLE" "$SETTINGS"
        log "已从模板生成 $SETTINGS —— 记得把 __GATEWAY_BASE_URL__ 换成你的网关地址"
        CHANGED=true
    else
        log "未找到 settings.yaml.example，跳过（不影响 profile/插件）"
    fi
fi

# ---------- 8) 有实际变更才重启服务，避免无谓中断 ----------
if ! $CHANGED; then
    log "无变更，跳过服务重启"
    exit 0
fi

if $NO_RESTART; then
    log "配置已更新，但指定了 --no-restart：请稍后手动重启 dsh-web 服务生效"
    log "  macOS: launchctl kickstart -k gui/$(id -u)/com.user.dsh-web"
    log "  Linux: systemctl --user restart dsh-web.service"
    exit 0
fi

log "检测到配置变更，重启 dsh-web 服务（页面会断几秒，刷新即可）..."
case "$(uname -s)" in
    Darwin)
        launchctl kickstart -k "gui/$(id -u)/com.user.dsh-web"
        ;;
    Linux)
        systemctl --user restart dsh-web.service
        ;;
    *)
        log "未识别到服务管理器，请手动重启 dsh web"
        exit 0
        ;;
esac

for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" 2>/dev/null || true)"
    case "$code" in
        2*|3*|4*|5*) log "服务已恢复 (HTTP $code)"; exit 0 ;;
    esac
    sleep 1
done
die "服务未在 30 秒内恢复，请检查服务状态"
