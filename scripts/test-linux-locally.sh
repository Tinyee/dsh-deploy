#!/bin/bash
# ============================================================
# test-linux-locally.sh — 在 macOS 上用"假 systemctl"隔离演练
#                        Linux 版 setup-dsh-linux.sh 的完整流程
#
# 安全设计:
#   - 全部隔离在 /tmp/dsh-linux-test（scratch HOME + DSH_HOME）
#   - 测试端口 3099，与真实服务 3080 无关
#   - 模拟进程只用 node 起的微型 HTTP 服务器，不碰真实 dsh 服务
#   - 假 systemctl 只做两件事: 记录调用 + enable --now 时拉起模拟服务
#
# 用法: ~/.dsh/test-linux-locally.sh
# ============================================================
set -euo pipefail

SCRATCH="/tmp/dsh-linux-test"
export SCRATCH
SHIM="$SCRATCH/bin"
export HOME="$SCRATCH"
export DSH_HOME="$SCRATCH/.dsh"
export DSH_WEB_PORT=3099
export PATH="$SHIM:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NODE_BIN="$(command -v node)"
export NODE_BIN
HTTP_ONE_LINER='require("http").createServer((q,s)=>{s.end("ok")}).listen(process.env.DSH_WEB_PORT,"127.0.0.1")'
export HTTP_ONE_LINER

echo "=== 1) 准备隔离环境 $SCRATCH ==="
rm -rf "$SCRATCH"
mkdir -p "$SHIM" "$DSH_HOME"

# 预置 runtime 副本（从真实副本复制，跳过 npm 下载，加快测试）
# 注意: 不预置升级脚本 —— 验证 setup 从自身目录兜底复制的新逻辑
cp -R /Users/edy/.dsh/runtime "$DSH_HOME/runtime"

# 假 systemctl: 记录调用；enable --now dsh-web.service 时模拟 systemd 拉起服务
cat > "$SHIM/systemctl" <<'SHIMEOF'
#!/bin/bash
echo "systemctl $*" >> "$SCRATCH/systemctl.log"
case "$*" in
  *"enable --now dsh-web.service"*)
    nohup "$NODE_BIN" -e "$HTTP_ONE_LINER" >/dev/null 2>&1 &
    echo "  [shim] spawned pid $!" >> "$SCRATCH/systemctl.log"
    ;;
esac
exit 0
SHIMEOF
chmod +x "$SHIM/systemctl"

echo "=== 2) 起一个\"旧进程\"占用 3099（模拟终端里跑着的服务）==="
"$NODE_BIN" -e "$HTTP_ONE_LINER" >/dev/null 2>&1 &
OLD_PID=$!
echo "旧进程 pid=$OLD_PID"
sleep 1

echo ""
echo "=== 3) 运行 bootstrap-dsh-linux.sh（从零引导 → 委派 setup 完整安装流程）==="
/Users/edy/.dsh/bootstrap-dsh-linux.sh
echo "setup exit=$?"

echo ""
echo "=== 4) 断言检查 ==="
echo "--- systemd 单元文件（应有 dsh-web.service + dsh-update.service/.timer）---"
ls "$SCRATCH/.config/systemd/user/"
echo "--- systemctl 调用记录 ---"
cat "$SCRATCH/systemctl.log" 2>/dev/null || echo "(无日志)"
echo "--- 端口 3099 占用（应已被 shim 拉起的进程接管，且不是旧进程 ${OLD_PID}）---"
lsof -nP -iTCP:3099 -sTCP:LISTEN -t 2>/dev/null | head -1 || true
echo "--- HTTP 响应 ---"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:3099

echo ""
echo "=== 5) 幂等性: 再跑一遍（应显示跳过/直接完成，不报错）==="
/Users/edy/.dsh/setup-dsh-linux.sh >/dev/null 2>&1 && echo "第二次运行 exit=0 ✅" || echo "第二次运行失败 ❌"

echo ""
echo "=== 6) --check 只读状态 ==="
/Users/edy/.dsh/setup-dsh-linux.sh --check

echo ""
echo "=== 7) 清理测试进程 ==="
pkill -f "DSH_WEB_PORT.*127.0.0.1" 2>/dev/null || true
pkill -f "http.server" 2>/dev/null || true
echo "清理完成。隔离目录保留在 ${SCRATCH}（systemctl.log、unit 文件）供查看"
