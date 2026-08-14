# dsh-deploy — DeepSeek Harness 三平台部署脚本 + 真机 CI

把 dsh web 从零配置为**开机自启后台服务**（崩溃自动重启 + 每日自动升级），
并配套 GitHub Actions **三平台真机测试**（macOS / Linux / Windows 真实 VM 上跑完整流程）。

## 目录

| 文件 | 用途 |
|---|---|
| `scripts/bootstrap-dsh-macos.sh` | macOS 从零安装（无 Node 自动 brew 装）→ 交给 setup |
| `scripts/bootstrap-dsh-linux.sh` | Linux 从零安装（apt/dnf/pacman）→ 交给 setup |
| `scripts/bootstrap-dsh-windows.ps1` | Windows 从零安装（winget + 自动下载 NSSM）→ 交给 setup |
| `scripts/setup-dsh-service.sh` | macOS：launchd 服务化（登录自启 + KeepAlive） |
| `scripts/setup-dsh-linux.sh` | Linux：systemd 用户服务（Restart=always + linger + 每日 timer） |
| `scripts/setup-dsh-windows.ps1` | Windows：NSSM 服务（优先）/ 任务计划程序（兜底） |
| `scripts/update-dsh.sh` 等 3 个 | 升级同步脚本（npm 检查 → 装新版本 → 重启服务） |
| `scripts/test-linux-locally.sh` | 非 Linux 机器上模拟演练 Linux 流程（假 systemctl） |
| `scripts/test-windows-locally.ps1` | 非 Windows 机器上模拟演练 Windows 流程（桩 cmdlet + 假 nssm） |

## 在真机上使用

```bash
# macOS / Linux
./scripts/bootstrap-dsh-macos.sh    # 或 bootstrap-dsh-linux.sh [--check]

# Windows（管理员 PowerShell）
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dsh-windows.ps1
```

## GitHub CI 真机测试

`.github/workflows/test-dsh.yml` 在三个托管 runner（真实 VM）上完整验证：

1. **从零引导安装**（真实 brew/apt/包管理器路径 + 服务注册）
2. **HTTP 服务可用**（127.0.0.1:3080）
3. **服务注册断言**（launchd running / systemd active+enabled / NSSM AUTO_START）
4. **崩溃自动重启**（kill -9 服务进程，等服务管理器拉起）
5. **升级链路**（故意降级到 0.0.1-rc.5 → 自动升回最新 → 重启生效）
6. **升级后复检** HTTP

### 已知边界

- **开机/登录时自启的真实时序**无法在托管 runner 验证（需要重启机器）；
  CI 验证的是"已注册为自启"状态（enabled / AUTO_START / linger）。
- Linux runner 无登录会话，workflow 已内置 `loginctl enable-linger` + XDG_RUNTIME_DIR 准备步骤。
- **计费**：private 仓库中 macOS 按 10 倍、Windows 按 3 倍计费（免费额度 2000 分钟/月）。
- 升级链路依赖 npm 网络访问（runner 上可用）。

## 初始化仓库

```bash
./init-repo.sh    # 同步 ~/.dsh 脚本 + git init + 本地提交
git remote add origin <仓库地址>
git push -u origin main
```
