# ============================================================
# setup-dsh-windows.ps1 — Windows 版：把 dsh web 配置为后台自启服务
#
# 用法（PowerShell，建议以管理员身份运行）:
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\setup-dsh-windows.ps1
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\setup-dsh-windows.ps1 -Check
#
# 依赖:
#   - Node.js（必须，已在 PATH 中）
#   - NSSM（推荐，https://nssm.cc 下载后把 nssm.exe 放进 PATH）
#     有 NSSM  → 真正的 Windows 服务：开机自启 + 崩溃自动重启
#     无 NSSM  → 退回任务计划程序：登录时启动，崩溃不会自动拉起
#
# 额外安装: 每日 10:00 自动升级检查任务（dsh-update）
# ============================================================
param([switch]$Check, [switch]$NoTimer)

$ErrorActionPreference = "Stop"

$DSH_HOME  = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" }
$RUNTIME   = Join-Path $DSH_HOME "runtime"
$LOGS      = Join-Path $DSH_HOME "logs"
$PORT      = 3080
$SVC       = "dsh-web"

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }

# ---------- 1) 定位 node ----------
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "找不到 node，请先安装 Node.js 并加入 PATH" }

# ---------- 2) 确保 runtime 副本存在 ----------
$bin = Join-Path $RUNTIME "node_modules\@deepseek-ai\dsh\lib\bin.js"
if (-not (Test-Path $bin)) {
    Log "runtime 副本缺失，尝试从 npm 缓存复制 ..."
    $src = $null
    $npxRoot = Join-Path $env:LOCALAPPDATA "npm-cache\_npx"
    if (Test-Path $npxRoot) {
        Get-ChildItem $npxRoot -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName "node_modules\@deepseek-ai\dsh\lib\bin.js")) { $src = $_.FullName }
        }
    }
    if ($src) {
        Log "从 $src 复制到 $RUNTIME"
        New-Item -ItemType Directory -Force -Path $RUNTIME | Out-Null
        Copy-Item (Join-Path $src "*") $RUNTIME -Recurse -Force
    } else {
        Log "npm 缓存没有，直接从 npm 安装到 $RUNTIME（需要网络）"
        New-Item -ItemType Directory -Force -Path $RUNTIME | Out-Null
        Push-Location $RUNTIME
        npm install @deepseek-ai/dsh --no-audit
        Pop-Location
    }
    if (-not (Test-Path $bin)) { throw "runtime 副本准备失败" }
}
$ver = & $node $bin --version 2>$null

# ---------- 3) 读取当前状态 ----------
function Get-PortPid {
    try { (Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction Stop | Select-Object -First 1).OwningProcess } catch { $null }
}
$oldPid = Get-PortPid
$existingSvc = Get-Service $SVC -ErrorAction SilentlyContinue

# ---------- 4) --Check 模式：只报告 ----------
if ($Check) {
    Write-Host "runtime  : $RUNTIME (v$ver)"
    if ($existingSvc) { Write-Host ("服务      : {0} ({1})" -f $SVC, $existingSvc.Status) } else { Write-Host "服务      : 未安装" }
    Write-Host ("端口 {0}  : {1}" -f $PORT, $(if ($oldPid) { "被 PID $oldPid 占用" } else { "空闲" }))
    exit 0
}

New-Item -ItemType Directory -Force -Path $LOGS | Out-Null

# ---------- 5) 安装服务：NSSM 优先，任务计划程序兜底 ----------
$nssm = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssm) {
    $nssmExe = $nssm.Source
    if ($existingSvc) { & $nssmExe remove $SVC confirm | Out-Null }
    Log "使用 NSSM 安装服务 $SVC ..."
    & $nssmExe install $SVC $node "`"$bin`" web" | Out-Null
    & $nssmExe set $SVC AppDirectory $HOME
    & $nssmExe set $SVC AppEnvironmentExtra "DSH_HOME=$DSH_HOME"
    & $nssmExe set $SVC AppStdout (Join-Path $LOGS "dsh-web.log")
    & $nssmExe set $SVC AppStderr (Join-Path $LOGS "dsh-web.err.log")
    & $nssmExe set $SVC AppExit Default Restart        # 崩溃自动重启
    & $nssmExe set $SVC Start SERVICE_AUTO_START       # 开机自启
    & $nssmExe start $SVC
    Log "服务已启动（NSSM：开机自启 + 崩溃自动重启）"
} else {
    Log "未安装 NSSM（https://nssm.cc 下载后把 nssm.exe 放入 PATH 可获得完整服务能力）"
    Log "退回任务计划程序：登录时自动启动（崩溃不会自动拉起）"
    $action = New-ScheduledTaskAction -Execute $node -Argument "`"$bin`" web" -WorkingDirectory $HOME
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $SVC -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $SVC
    Log "任务计划程序已注册并启动"
}

# ---------- 6) 停旧进程，等服务接管 ----------
if ($oldPid) {
    Log "停止占用端口 $PORT 的旧进程 (PID $oldPid) ..."
    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
}

Log "等待服务接管端口 $PORT ..."
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PORT" -UseBasicParsing -TimeoutSec 2
        Log "✅ 完成：服务已接管端口 $PORT，HTTP $($r.StatusCode)"
        break
    } catch {
        if ($i -eq 29) { throw "服务未在 30 秒内恢复，请检查服务状态" }
    }
}

# ---------- 7) 每日 10:00 自动升级检查任务 ----------
if (-not $NoTimer) {
    $updateScript = Join-Path $DSH_HOME "update-dsh-windows.ps1"
    if (-not (Test-Path $updateScript)) {
        $candidate = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "update-dsh-windows.ps1"
        if (Test-Path $candidate) {
            Log "从脚本目录复制升级脚本到 $DSH_HOME"
            Copy-Item $candidate $updateScript -Force
        }
    }
    if (Test-Path $updateScript) {
        $uAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
        $uTrigger = New-ScheduledTaskTrigger -Daily -At 10:00AM
        $uSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $uPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName "dsh-update" -Action $uAction -Trigger $uTrigger -Settings $uSettings -Principal $uPrincipal -Force | Out-Null
        Log "已注册每日升级检查任务 dsh-update（每天 10:00）"
    } else {
        Log "提示：未找到 $updateScript，跳过每日升级检查"
    }
}
Log "全部完成"
