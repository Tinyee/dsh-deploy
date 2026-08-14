# ============================================================
# test-windows-locally.ps1 — 在 macOS 上用"桩函数 + 假 nssm"
#                           隔离演练 Windows 版脚本的完整流程
#
# 安全设计:
#   - 全部隔离在 /tmp/dsh-windows-test（scratch DSH_HOME）
#   - Get-NetTCPConnection 桩始终返回空 → 脚本不会 Stop-Process 任何真实进程
#   - 假 nssm 只记录调用；Invoke-WebRequest 只读访问 127.0.0.1:3080（真实服务，无副作用）
#   - 场景 6 会在 scratch runtime 里 npm 降级/升级，不碰真实 ~/.dsh/runtime
#
# 用法: pwsh -NoProfile -File ~/.dsh/test-windows-locally.ps1
# ============================================================
$ErrorActionPreference = "Stop"

$SCRATCH   = "/tmp/dsh-windows-test"
$SHIM      = "$SCRATCH/bin"
$env:DSH_HOME = "$SCRATCH/.dsh"
$STUB_LOG  = "$env:DSH_HOME/logs/stub.log"
$NSSM_LOG  = "$env:DSH_HOME/logs/nssm.log"
$stubsFile = "$SCRATCH/stubs.ps1"
$pwsh      = (Get-Command pwsh).Source
$setup     = "/Users/edy/.dsh/setup-dsh-windows.ps1"
$update    = "/Users/edy/.dsh/update-dsh-windows.ps1"

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

Say "=== 0) 准备隔离环境 $SCRATCH ==="
Remove-Item -Recurse -Force $SCRATCH -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $SHIM, "$env:DSH_HOME/logs" | Out-Null
Copy-Item -Recurse -Force /Users/edy/.dsh/runtime "$env:DSH_HOME/runtime"
Copy-Item -Force /Users/edy/.dsh/update-dsh-windows.ps1 "$env:DSH_HOME/"

# ---- 假 nssm：记录调用、假装成功 ----
$nssmFake = "$SHIM/nssm"
@'
#!/bin/bash
echo "nssm $*" >> "$NSSM_LOG" 2>/dev/null
exit 0
'@ | Set-Content -Path $nssmFake -Encoding ascii
& chmod +x $nssmFake

# ---- 桩定义：遮蔽 Windows 专属 cmdlet ----
@'
function Log-Stub { param($m) Add-Content -Path $env:STUB_LOG -Value ("[stub] " + $m) }

# 端口检查：始终"无占用"→ 脚本不会去杀任何进程（关键安全点）
function Get-NetTCPConnection { param($LocalPort, $State) Log-Stub "Get-NetTCPConnection port=$LocalPort -> none"; return $null }

# 服务查询：始终"未安装"
function Get-Service { param($Name, $ErrorAction) Log-Stub "Get-Service $Name -> not installed"; return $null }

function New-ScheduledTaskAction   { param($Execute, $Argument, $WorkingDirectory) Log-Stub "New-ScheduledTaskAction exe=$Execute"; [pscustomobject]@{ Execute=$Execute; Argument=$Argument } }
function New-ScheduledTaskTrigger  { param([switch]$AtLogOn, $User, [switch]$Daily, $At) Log-Stub "New-ScheduledTaskTrigger AtLogOn=$AtLogOn Daily=$Daily At=$At"; [pscustomobject]@{ AtLogOn=$AtLogOn; User=$User; Daily=$Daily; At=$At } }
function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit) Log-Stub "New-ScheduledTaskSettingsSet"; [pscustomobject]@{ ExecutionTimeLimit=$ExecutionTimeLimit } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) Log-Stub "New-ScheduledTaskPrincipal"; [pscustomobject]@{ UserId=$UserId; RunLevel=$RunLevel } }
function Register-ScheduledTask    { param($TaskName, $Action, $Trigger, $Settings, $Principal, [switch]$Force) Log-Stub "Register-ScheduledTask $TaskName"; [pscustomobject]@{ TaskName=$TaskName } }
function Start-ScheduledTask       { param($TaskName) Log-Stub "Start-ScheduledTask $TaskName" }
function Restart-ScheduledTask     { param($TaskName) Log-Stub "Restart-ScheduledTask $TaskName" }
'@ | Set-Content -Path $stubsFile -Encoding utf8

function Run-Scenario([string]$name, [string]$scriptPath, [string]$extraArgs, [bool]$withNssm) {
    $origPath = $env:PATH
    $env:PATH = $(if ($withNssm) { "$SHIM`:$origPath" } else { $origPath })
    $env:STUB_LOG = $STUB_LOG
    $env:NSSM_LOG = $NSSM_LOG
    $cmd = ". '$stubsFile'; & '$scriptPath' $extraArgs"
    Say "=== $name ==="
    $out = & $pwsh -NoProfile -Command $cmd 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "    $_" }
    Write-Host "    [exit=$code]"
    return $code
}

function Test-Syntax([string]$path, [string]$label) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Say "=== $label : 语法错误 ==="
        $errors | ForEach-Object { Write-Host "    !! line $($_.Extent.StartLineNumber): $($_.Message)" }
        return 1
    }
    Say "=== $label : SYNTAX OK ==="
    return 0
}

$fail = 0

# ---- 场景 1: 语法检查（官方解析器，不执行）----
$fail += Test-Syntax $setup "setup-dsh-windows.ps1 语法"
$fail += Test-Syntax $update "update-dsh-windows.ps1 语法"
$fail += Test-Syntax $stubsFile "stubs.ps1 语法"

# ---- 场景 2: setup -Check（只读）----
$fail += Run-Scenario "2) setup -Check（只读状态）" $setup "-Check" $false

# ---- 场景 3: setup 全量（无 nssm → 计划任务分支）----
$fail += Run-Scenario "3) setup 全量（无 nssm → 计划任务分支）" $setup "" $false

# ---- 场景 4: setup 全量（有假 nssm → NSSM 分支）----
$fail += Run-Scenario "4) setup 全量（假 nssm → NSSM 分支）" $setup "" $true

# ---- 场景 5: update -Check（应显示已是最新）----
$fail += Run-Scenario "5) update -Check（应已是最新）" $update "-Check" $true

# ---- 场景 6: 降级后全量升级（走完整升级链路）----
Say "=== 6a) 把 scratch runtime 故意降级到 0.0.1-rc.5 ==="
Push-Location "$env:DSH_HOME/runtime"
npm install @deepseek-ai/dsh@0.0.1-rc.5 2>&1 | Out-Null
Pop-Location
$oldVer = & $pwsh -NoProfile -Command "& node '$env:DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js' --version"
Write-Host "    降级后版本: $oldVer"
$fail += Run-Scenario "6b) update 全量（应自动升回最新 + 重启）" $update "" $true
$newVer = & $pwsh -NoProfile -Command "& node '$env:DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js' --version"
Write-Host "    升级后版本: $newVer"

# ---- 场景 7: bootstrap 从零引导（假 nssm → 委派 setup NSSM 分支）----
$fail += Run-Scenario "7) bootstrap 从零引导（假 nssm → 委派 setup NSSM 分支）" "/Users/edy/.dsh/bootstrap-dsh-windows.ps1" "" $true

# ---- 断言汇总 ----
Say "=== 断言 ==="
Write-Host "--- stub 调用记录（计划任务分支场景应含 Register/Start-ScheduledTask）---"
Get-Content $STUB_LOG -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
Write-Host "--- nssm 调用记录（场景 4/6b 应含 install/set/start/restart）---"
Get-Content $NSSM_LOG -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Say "=== 结果: $(if ($fail -eq 0) { '全部通过 ✅' } else { "$fail 个场景失败 ❌" }) ==="
exit $fail
