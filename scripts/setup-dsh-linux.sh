#!/bin/bash
# ============================================================
# setup-dsh-linux.sh — Linux (systemd) 版：一键把 dsh web 配置为
#                     开机自启后台服务（登录自启 + 崩溃自动重启）
#
# 用法:
#   ~/.dsh/setup-dsh-linux.sh          # 执行安装（幂等）
#   ~/.dsh/setup-dsh-linux.sh --check  # 只检查状态
#   ~/.dsh/setup-dsh-linux.sh --no-timer  # 安装服务但不装每日升级检查
#
# 说明:
#   - 生成 systemd 用户服务 ~/.config/systemd/user/dsh-web.service
#   - 尝试 loginctl enable-linger 实现"未登录也开机自启"
#     （若无权限，需 root 执行: loginctl enable-linger <用户名>）
#   - 若在 SSH/无桌面会话里运行，systemctl --user 可能连不上总线，
#     请先: export XDG_RUNTIME_DIR=/run/user/$(id -u)
# ============================================================
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME="$DSH_HOME/runtime"
UNIT="dsh-web.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT"
PORT="${DSH_WEB_PORT:-3080}"
MODE="${1:-}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "!! $*"; exit 1; }

# ---------- 1) 定位 node ----------
NODE_BIN="$(command -v node 2>/dev/null || true)"
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
        log "npx 缓存也没有，直接从 npm 安装到 $RUNTIME（需要网络）"
        mkdir -p "$RUNTIME"
        (cd "$RUNTIME" && npm install @deepseek-ai/dsh)
    fi
    [ -f "$BIN" ] || die "runtime 副本准备失败"
fi
VERSION="$("$NODE_BIN" "$BIN" --version 2>/dev/null || echo unknown)"

# ---------- 3) 生成 systemd 用户单元 ----------
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE.tmp" <<EOF
[Unit]
Description=DeepSeek Harness web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$NODE_BIN $BIN web
Environment=DSH_HOME=$DSH_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$HOME
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
mv "$UNIT_FILE.tmp" "$UNIT_FILE"

# ---------- 4) 读取当前状态 ----------
SERVICE_ACTIVE=false
systemctl --user is-active "$UNIT" >/dev/null 2>&1 && SERVICE_ACTIVE=true

PORT_PID="$(ss -tlnpH "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1 || true)"
[ -z "$PORT_PID" ] && PORT_PID="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"

# ---------- 5) --check 模式：只报告 ----------
if [ "$MODE" = "--check" ]; then
    echo "runtime  : $RUNTIME (v$VERSION)"
    echo "unit     : $UNIT_FILE [$($SERVICE_ACTIVE && echo active || echo inactive)]"
    echo "端口 $PORT : $([ -n "$PORT_PID" ] && echo "被 PID $PORT_PID 占用" || echo 空闲)"
    systemctl --user is-enabled "$UNIT" >/dev/null 2>&1 && echo "开机自启  : ✅ 已启用" || echo "开机自启  : 未启用"
    exit 0
fi

# ---------- 6) 启用服务 ----------
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT" || die "systemctl --user 失败（SSH 环境请先 export XDG_RUNTIME_DIR=/run/user/\$(id -u)）"

# 未登录也开机自启（linger）
if loginctl enable-linger "$USER" 2>/dev/null; then
    log "已启用 linger：未登录也会开机自启"
else
    log "提示：如需未登录自启，请用 root 执行: loginctl enable-linger $USER"
fi

# ---------- 7) 停旧进程，等待 systemd 接管 ----------
if [ -n "$PORT_PID" ]; then
    log "停止占用端口 $PORT 的旧进程 (PID $PORT_PID) ..."
    kill "$PORT_PID" 2>/dev/null || true
fi

log "等待 systemd 接管端口 $PORT ..."
for i in $(seq 1 30); do
    if systemctl --user is-active --quiet "$UNIT"; then
        holder="$(ss -tlnpH "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1 || true)"
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT" 2>/dev/null || true)"
        case "$code" in
            2*|3*|4*|5*)
                log "✅ 完成：systemd 服务已接管端口 $PORT，HTTP $code"
                log "   以后开机自动启动、崩溃自动重启（Restart=always）"
                break
                ;;
        esac
    fi
    sleep 1
    [ "$i" = "30" ] && die "等待超时，检查: systemctl --user status $UNIT"
done

# ---------- 8) 每日 10:00 自动升级检查（timer）----------
if [ "$MODE" != "--no-timer" ]; then
    UPDATE_SCRIPT="$DSH_HOME/update-dsh-linux.sh"
    if [ -f "$UPDATE_SCRIPT" ]; then
        cat > "$UNIT_DIR/dsh-update.service" <<EOF
[Unit]
Description=DeepSeek Harness daily update check

[Service]
Type=oneshot
ExecStart=/bin/bash $UPDATE_SCRIPT
EOF
        cat > "$UNIT_DIR/dsh-update.timer" <<EOF
[Unit]
Description=Run dsh update check daily at 10:00

[Timer]
OnCalendar=*-*-* 10:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now dsh-update.timer
        log "已启用每日升级检查 timer（每天 10:00，错过补跑）"
    else
        log "提示：未找到 $UPDATE_SCRIPT，跳过每日升级检查"
    fi
fi
log "全部完成"
