# ============================================================
# bootstrap-dsh-windows.ps1 — Windows 从零安装 DeepSeek Harness
#
# 流程: ① 无 Node 则用 winget 安装（无 winget 则提示手动装）
#       → ② 无 NSSM 则自动下载到 %LOCALAPPDATA%\dsh-tools
#       → ③ 交给 setup-dsh-windows.ps1（服务注册 + 每日升级检查）
#
# 用法（管理员 PowerShell）:
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\bootstrap-dsh-windows.ps1
#   powershell -ExecutionPolicy Bypass -File ~\.dsh\bootstrap-dsh-windows.ps1 -Check
# ============================================================
$ErrorActionPreference = "Stop"

$DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- [1/3] Node.js ----------
Write-Host "=== [1/3] 检查 Node.js ==="
if (Get-Command node -ErrorAction SilentlyContinue) {
    Write-Host "Node.js 已安装: $(& node --version)"
} else {
    Write-Host "未检测到 Node.js，尝试用 winget 安装 ..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        & $winget.Source install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        # winget 安装后刷新 PATH（当前会话可能拿不到新路径）
        $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Host "Node.js 安装完成: $(& node --version)"
    } else {
        Write-Host "!! 未检测到 winget。请到 https://nodejs.org 下载 LTS 版安装后重试。"
        exit 1
    }
}

# ---------- [2/3] NSSM（可选增强，自动下载）----------
Write-Host ""
Write-Host "=== [2/3] 检查 NSSM ==="
if (Get-Command nssm -ErrorAction SilentlyContinue) {
    Write-Host "NSSM 已就位"
} else {
    Write-Host "未检测到 NSSM，尝试自动下载 ..."
    $tools = Join-Path $env:LOCALAPPDATA "dsh-tools"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $nssmZip = Join-Path $tools "nssm.zip"
    try {
        Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
        Expand-Archive -Path $nssmZip -DestinationPath $tools -Force
        $nssmExe = Get-ChildItem $tools -Recurse -Filter nssm.exe | Select-Object -First 1
        if ($nssmExe) {
            Copy-Item $nssmExe.FullName $tools -Force
            $env:PATH = "$tools;$env:PATH"
            Write-Host "NSSM 已就位: $tools\nssm.exe"
            Write-Host "（如需永久生效，把 $tools 加入系统 PATH 环境变量）"
        } else {
            throw "nssm.exe 未在压缩包中找到"
        }
    } catch {
        Write-Host "!! NSSM 下载失败: $($_.Exception.Message)"
        Write-Host "   将退回任务计划程序方案（登录自启，崩溃不自动拉起）。"
    }
}

# ---------- [3/3] 交给 setup ----------
Write-Host ""
Write-Host "=== [3/3] 配置 dsh 服务 ==="
& (Join-Path $DIR "setup-dsh-windows.ps1") @args
