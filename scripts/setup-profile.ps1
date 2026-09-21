# ============================================================
# setup-profile.ps1 — Windows 版：把 dsh 从"裸官方安装"复现为
#                      完整自定义环境（与 setup-profile.sh 对应）
#
#   ① web profile 自动初始化（首次使用时由 dsh 从随附模板创建）
#   ② 安装 dshmarket 插件市场（幂等: dsh plugin --profile web add dshmarket）
#   ③ settings.yaml 不存在时从 settings.yaml.example 生成（绝不覆盖已有配置）
#   ④ 检测到实际变更时自动重启 dsh-web 服务并等待端口恢复
#
# 用法（PowerShell，建议以管理员身份运行）:
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\setup-profile.ps1
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\setup-profile.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\setup-profile.ps1 -NoRestart
# ============================================================
param([switch]$Check, [switch]$NoRestart)

$ErrorActionPreference = "Stop"

$DSH_HOME = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" }
$RUNTIME  = Join-Path $DSH_HOME "runtime"
$TOOLS    = Join-Path $DSH_HOME "tools"
$BIN      = Join-Path $RUNTIME "node_modules\@deepseek-ai\dsh\lib\bin.js"
$PROFILE_JSON = Join-Path $DSH_HOME "profiles\web\package.json"
$SETTINGS = Join-Path $DSH_HOME "settings.yaml"
$PNPM_BIN = Join-Path $TOOLS "node_modules\.bin\pnpm.cmd"
$PORT     = 3080
$SVC      = "dsh-web"

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }

# 服务是否"活着"：拿到任何 HTTP 响应（2xx-5xx）都算恢复，
# 不苛求 200 —— 当前 dsh web 对匿名请求返回 401/404 是正常行为。
function Test-HttpAlive {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PORT" -UseBasicParsing -TimeoutSec 2
        return $true
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { return $true }
        return $false
    }
}

# ---------- 1) 定位 node ----------
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "找不到 node，请先安装 Node.js 并加入 PATH" }

# ---------- 2) 确保 runtime 副本存在 ----------
if (-not (Test-Path $BIN)) {
    Log "runtime 副本缺失，直接从 npm 安装到 $RUNTIME（需要网络）..."
    New-Item -ItemType Directory -Force -Path $RUNTIME | Out-Null
    Push-Location $RUNTIME
    try { npm install @deepseek-ai/dsh } finally { Pop-Location }
    if (-not (Test-Path $BIN)) { throw "runtime 副本准备失败" }
}
$version = & $node $BIN --version 2>$null

# ---------- 3) 评估当前状态（只读）----------
$marketOk = $false
if (Test-Path $PROFILE_JSON) {
    $marketOk = [bool](Select-String -Path $PROFILE_JSON -Pattern '"dshmarket"' -Quiet)
}
$settingsOk = Test-Path $SETTINGS
$pnpmOk = Test-Path $PNPM_BIN

# ---------- 4) -Check 模式：只报告 ----------
if ($Check) {
    Write-Host "runtime    : $RUNTIME (v$version)"
    if (Test-Path $PROFILE_JSON) { Write-Host "profile    : $PROFILE_JSON [存在]" } else { Write-Host "profile    : $PROFILE_JSON [缺失]" }
    if ($marketOk) { Write-Host "dshmarket  : [已安装]" } else { Write-Host "dshmarket  : [未安装]" }
    if ($settingsOk) { Write-Host "settings   : $SETTINGS [存在]" } else { Write-Host "settings   : $SETTINGS [缺失]" }
    if ($pnpmOk) { Write-Host "pnpm       : 就绪" } else { Write-Host "pnpm       : 缺失（将由本脚本安装到 $TOOLS）" }
    exit 0
}

$changed = $false

# ---------- 5) 确保 pnpm 可用（dsh plugin 依赖它）----------
if ($pnpmOk) {
    Log "pnpm 就绪: $PNPM_BIN"
} else {
    Log "未找到 pnpm，安装到 $TOOLS ..."
    New-Item -ItemType Directory -Force -Path $TOOLS | Out-Null
    Push-Location $TOOLS
    try { npm install pnpm } finally { Pop-Location }
    if (-not (Test-Path $PNPM_BIN)) { throw "pnpm 安装失败" }
}
$env:PATH = "$(Split-Path $PNPM_BIN);$env:PATH"

# ---------- 6) 安装/确认 dshmarket（幂等）----------
if ($marketOk) {
    Log "profile web 已包含 dshmarket，跳过安装"
} else {
    Log "profile web 缺少 dshmarket，执行: dsh plugin --profile web add dshmarket"
    & $node $BIN plugin --profile web add dshmarket
    if ($LASTEXITCODE -ne 0) { throw "安装 dshmarket 失败" }
    $changed = $true
}

# ---------- 7) settings.yaml：仅首次写入，绝不覆盖 ----------
if ($settingsOk) {
    Log "settings.yaml 已存在，保留不动（如需更新请手动编辑）"
} else {
    $example = Join-Path $PSScriptRoot "settings.yaml.example"
    if (Test-Path $example) {
        Copy-Item $example $SETTINGS -Force
        Log "已从模板生成 $SETTINGS —— 记得把 __GATEWAY_BASE_URL__ 换成你的网关地址"
        $changed = $true
    } else {
        Log "未找到 settings.yaml.example，跳过（不影响 profile/插件）"
    }
}

# ---------- 8) 有实际变更才重启服务，避免无谓中断 ----------
if (-not $changed) { Log "无变更，跳过服务重启"; exit 0 }

if ($NoRestart) {
    Log "配置已更新，但指定了 -NoRestart：请稍后手动重启 dsh-web 服务生效"
    Log "  NSSM: nssm restart dsh-web    计划任务: Restart-ScheduledTask dsh-web"
    exit 0
}

Log "检测到配置变更，重启 $SVC 服务 ..."
$nssm = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssm) {
    & $nssm.Source restart $SVC | Out-Null
} else {
    Restart-ScheduledTask -TaskName $SVC
}

for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-HttpAlive) { Log "服务已恢复"; exit 0 }
}
throw "服务未在 30 秒内恢复，请检查服务状态"
