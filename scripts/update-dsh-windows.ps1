# ============================================================
# update-dsh-windows.ps1 — Windows 版：升级 @deepseek-ai/dsh 到最新版，
#                         同步 ~\.dsh\runtime 副本并重启服务
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\update-dsh-windows.ps1
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\update-dsh-windows.ps1 -Check
# ============================================================
param([switch]$Check)

$ErrorActionPreference = "Stop"

$DSH_HOME = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" }
$RUNTIME  = Join-Path $DSH_HOME "runtime"
$BIN      = Join-Path $RUNTIME "node_modules\@deepseek-ai\dsh\lib\bin.js"
$SVC      = "dsh-web"
$LOG      = Join-Path $DSH_HOME "logs\dsh-update.log"
$PORT     = 3080

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Write-Host $line
    New-Item -ItemType Directory -Force -Path (Split-Path $LOG) | Out-Null
    Add-Content -Path $LOG -Value $line
}

# --- 1) 当前副本版本 vs npm 最新版本 ---
$current = & node $BIN --version 2>$null
$latest  = & npm view @deepseek-ai/dsh version 2>$null

Log "当前副本版本: $current"
Log "npm 最新版本: $latest"

if ($current -eq $latest) { Log "已是最新版本，无需更新"; exit 0 }
if ($Check) { Log "检测到新版本 $latest（当前 $current），-Check 模式跳过升级"; exit 0 }

# --- 2) 在 runtime 目录里原地安装最新版 ---
Log "开始升级副本: npm install @deepseek-ai/dsh@$latest"
Push-Location $RUNTIME
npm install "@deepseek-ai/dsh@$latest" --no-audit
Pop-Location

# --- 3) 校验安装结果 ---
$new = & node $BIN --version 2>$null
if ($new -ne $latest) { Log "!! 升级后版本校验失败（期望 $latest，实际 $new）"; exit 1 }
Log "副本升级成功: $current -> $new"

# --- 4) 重启服务（NSSM 服务 或 任务计划程序，自动识别）---
$nssm = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssm) {
    Log "重启 NSSM 服务 $SVC ..."
    & $nssm.Source restart $SVC | Out-Null
} else {
    Log "重启计划任务 $SVC ..."
    Restart-ScheduledTask -TaskName $SVC
}

# --- 5) 等待端口恢复 ---
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PORT" -UseBasicParsing -TimeoutSec 2
        Log "服务已恢复 (HTTP $($r.StatusCode))"
        exit 0
    } catch {}
}
Log "!! 服务未在 30 秒内恢复，请检查服务状态"
exit 1
