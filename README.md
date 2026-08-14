# dsh-deploy

DeepSeek Harness 一键部署：**从零安装到开机自启后台服务**（崩溃自动重启 + 每日自动升级），支持 macOS / Linux / Windows。

## 安装

```bash
# macOS / Linux：一条命令
./install.sh

# Windows（管理员 PowerShell）
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dsh-windows.ps1
```

装完后浏览器打开 http://127.0.0.1:3080 即可使用；终端、重启电脑都不影响。

## 它做了什么

- 无 Node 时自动安装（brew / apt / winget）
- 服务化：launchd / systemd / NSSM，开机自启 + 崩溃自动重启
- 每天 10:00 自动检查新版本，有新版自动升级并重启
- 全程幂等，可重复运行；`--check` 只查看状态

## 测试

三平台真机 CI 覆盖：从零安装、服务注册、HTTP、崩溃自愈、升级链路。
见 [Actions](https://github.com/Tinyee/dsh-deploy/actions)。

## 常见命令

```bash
./install.sh --check          # 查看状态
scripts/update-dsh.sh         # 手动检查升级（Linux: update-dsh-linux.sh）
```

`scripts/` 下的脚本可从 `~/.dsh` 用 `./init-repo.sh` 同步维护。
