#!/bin/bash
# ============================================================
# setup-dsh-service.sh — 一键把 dsh web 从"终端前台运行"
#                       切换为 macOS 系统后台服务
#                        （登录自启 + 崩溃自动重启）
#
# 用法:
#   ~/.dsh/setup-dsh-service.sh          # 执行迁移（幂等，可重复跑）
#   ~/.dsh/setup-dsh-service.sh --check  # 只检查当前状态，不改动任何东西
#
# 环境变量: DSH_HOME 覆盖配置目录（默认 ~/.dsh）
#           DSH_WEB_PORT 覆盖检查端口（默认 3080）
#
# 说明: 运行时若检测到旧进程占着端口，会停止它（页面断几秒，刷新即可）。
#       若系统服务已在运行且配置未变，则什么都不做直接退出。
# ============================================================
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME="$DSH_HOME/runtime"
LABEL="com.user.dsh-web"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PLIST_TMP="$PLIST.new"
PORT="${DSH_WEB_PORT:-3080}"
LOG_DIR="$DSH_HOME/logs"
MODE="${1:-}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "!! $*"; exit 1; }

# ---------- 1) 定位 node ----------
NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -z "$NODE_BIN" ] && [ -x /opt/homebrew/bin/node ] && NODE_BIN=/opt/homebrew/bin/node
[ -z "$NODE_BIN" ] && die "找不到 node，请先安装 Node.js"

# ---------- 2) 确保 runtime 副本存在 ----------
BIN="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
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

# ---------- 3) 生成 plist（与当前部署格式保持一致）----------
cat > "$PLIST_TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$BIN</string>
        <string>web</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>DSH_HOME</key>
        <string>$DSH_HOME</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>$HOME</string>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/dsh-web.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/dsh-web.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST_TMP" >/dev/null 2>&1 || die "生成的 plist 非法"

# ---------- 4) 读取当前状态 ----------
SERVICE_LOADED=false
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && SERVICE_LOADED=true

PLIST_SAME=false
[ -f "$PLIST" ] && diff -q "$PLIST" "$PLIST_TMP" >/dev/null 2>&1 && PLIST_SAME=true

PORT_PID="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
LAUNCHD_PID=""
if $SERVICE_LOADED; then
    LAUNCHD_PID="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}' || true)"
fi

# ---------- 5) --check 模式：只报告 ----------
if [ "$MODE" = "--check" ]; then
    echo "runtime 副本 : $RUNTIME (v$VERSION)"
    echo "plist        : $PLIST [$($SERVICE_LOADED && echo 已加载 || echo 未加载)]"
    echo "端口 $PORT    : $([ -n "$PORT_PID" ] && echo "被 PID $PORT_PID 占用" || echo 空闲)"
    if [ -n "$LAUNCHD_PID" ]; then
        echo "系统服务     : 运行中 (pid $LAUNCHD_PID)"
        if [ "$PORT_PID" = "$LAUNCHD_PID" ]; then
            echo "接管状态     : ✅ launchd 已接管端口，无需操作"
        else
            echo "接管状态     : ⚠️ 端口还被其他进程占用（运行脚本可自动切换）"
        fi
    else
        echo "系统服务     : 未运行"
        echo "接管状态     : ⚠️ 需要运行脚本完成迁移"
    fi
    exit 0
fi

# ---------- 6) 应用配置 ----------
mkdir -p "$LOG_DIR"
mv "$PLIST_TMP" "$PLIST"

if $SERVICE_LOADED && $PLIST_SAME; then
    log "服务已加载且配置未变，跳过重启"
else
    log "注册/刷新 launchd 服务 $LABEL ..."
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl bootstrap 失败"
    LAUNCHD_PID=""
fi

# ---------- 7) 让旧进程让出端口 ----------
if [ -n "$PORT_PID" ] && [ "$PORT_PID" != "$LAUNCHD_PID" ]; then
    log "停止占用端口 $PORT 的旧进程 (PID $PORT_PID)，页面会断几秒，稍后刷新即可"
    sleep 2
    kill "$PORT_PID" 2>/dev/null || true
fi

# ---------- 8) 等待系统服务接管并验证 ----------
log "等待 launchd 接管端口 $PORT ..."
TAKEOVER_OK=false
for i in $(seq 1 30); do
    NEW_PID="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}' || true)"
    if [ -n "$NEW_PID" ]; then
        holder="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
        if [ "$holder" = "$NEW_PID" ]; then
            code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" 2>/dev/null || true)"
            case "$code" in
                2*|3*|4*|5*)
                    log "✅ 完成：launchd 服务 (pid $NEW_PID) 已接管端口 ${PORT}，HTTP $code"
                    log "   以后开机自动启动、崩溃自动重启，终端可以随便关"
                    TAKEOVER_OK=true
                    break
                    ;;
            esac
        fi
    fi
    sleep 1
done
if ! $TAKEOVER_OK; then
    die "等待超时，请检查: launchctl print gui/$(id -u)/$LABEL"
fi

# ---------- 9) 每日升级检查 LaunchAgent ----------
UPDATE_LABEL="com.user.dsh-update"
UPDATE_PLIST="$HOME/Library/LaunchAgents/$UPDATE_LABEL.plist"
UPDATE_SCRIPT="$DSH_HOME/update-dsh.sh"
if [ ! -f "$UPDATE_SCRIPT" ] && [ -f "$(dirname "$0")/update-dsh.sh" ]; then
    log "从脚本目录复制升级脚本到 $DSH_HOME/"
    cp "$(dirname "$0")/update-dsh.sh" "$DSH_HOME/"
fi
if [ -f "$UPDATE_SCRIPT" ]; then
    cat > "$UPDATE_PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$UPDATE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$UPDATE_SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>10</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
    plutil -lint "$UPDATE_PLIST.new" >/dev/null 2>&1 || die "生成的升级检查 plist 非法"
    UP_LOADED=false
    launchctl print "gui/$(id -u)/$UPDATE_LABEL" >/dev/null 2>&1 && UP_LOADED=true
    UP_SAME=false
    [ -f "$UPDATE_PLIST" ] && diff -q "$UPDATE_PLIST" "$UPDATE_PLIST.new" >/dev/null 2>&1 && UP_SAME=true
    mv "$UPDATE_PLIST.new" "$UPDATE_PLIST"
    if $UP_LOADED && $UP_SAME; then
        log "每日升级检查已注册且配置未变"
    else
        launchctl bootout "gui/$(id -u)/$UPDATE_LABEL" >/dev/null 2>&1 || true
        if launchctl bootstrap "gui/$(id -u)" "$UPDATE_PLIST"; then
            log "已注册每日升级检查（每天 10:00）"
        else
            log "!! 升级检查 LaunchAgent 注册失败（不影响主服务）"
        fi
    fi
else
    log "提示：未找到 ${UPDATE_SCRIPT}，跳过每日升级检查"
fi
log "全部完成"
