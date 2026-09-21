# dsh-deploy

DeepSeek Harness 一键部署：**从零安装到开机自启后台服务**（崩溃自动重启 + 每日自动升级），支持 macOS / Linux / Windows。配套 `setup-profile.sh` 可一键复现**自定义环境**（插件市场 + 模型配置）。

## 安装

```bash
# macOS / Linux：一条命令
./install.sh

# Windows（管理员 PowerShell）
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dsh-windows.ps1
```

装完后浏览器打开 http://127.0.0.1:3080 即可使用；终端、重启电脑都不影响。

## 复现自定义环境（profile + 插件市场 + 模型配置）

裸安装只有官方 dsh。要复现"装了插件市场、配了自定义模型"的完整环境：

```bash
~/.dsh/setup-profile.sh          # 执行（幂等，可重复跑）
~/.dsh/setup-profile.sh --check  # 只报告状态
```

它做的事：

- **web profile 自动初始化**（首次由 dsh 从随附模板创建）
- **安装插件**（正式 `dsh plugin` 方式，幂等）：`dshmarket` 插件市场始终安装；其余插件来自 `$DSH_HOME/setup-profile.plugins`（每行一个包名，`#` 注释）或 `EXTRA_PLUGINS` 环境变量。示例见 `scripts/setup-profile.plugins.example`（Tailscale 面板 / 手机端 / DSH Remote 等）
- **生成 settings.yaml**：仅在文件不存在时从 `settings.yaml.example` 复制，**绝不覆盖已有配置**；复制后记得把 `__GATEWAY_BASE_URL__` 换成你的网关地址（不接自定义网关就删掉 `llm-deepseek` 段）
- **有实际变更才重启服务**并等待端口恢复，无变更则跳过，不打扰正在运行的服务

> 注：安装入口（install.sh / bootstrap）只负责部署层（runtime + 服务 + 每日升级），不自动写 settings.yaml——自定义网关地址属于你的隐私配置，由你决定是否启用。

> 注：**不再使用 node_modules 补丁（patch-*.js）**。旧方案直接改 DSH 源码，升级后容易失效；插件请一律用 `dsh plugin add` 正式安装（由插件系统管理、升级不丢）。`update-dsh.sh` 检测到遗留的 `patch-*.js` 时只会提示迁移，不会重放。

## 它做了什么

- 无 Node 时自动安装（brew / apt / winget）
- 服务化：launchd / systemd / NSSM，开机自启 + 崩溃自动重启
- 每天 10:00 自动检查新版本，有新版自动升级并重启
- 全程幂等，可重复运行；`--check` 只查看状态

## 测试

三平台真机 CI 覆盖：从零安装、自定义环境配置、服务注册、HTTP、崩溃自愈、升级链路。见 [Actions](https://github.com/Tinyee/dsh-deploy/actions)。

> 关于 HTTP 断言：当前 dsh web 对匿名请求返回 401/404 属正常行为，脚本与 CI 一律以"**拿到任何 HTTP 响应（2xx-5xx）即视为服务在线**"为准，不苛求 200。

## 常见命令

```bash
./install.sh --check            # 查看状态
~/.dsh/setup-profile.sh --check # 查看自定义环境状态
~/.dsh/update-dsh.sh            # 手动检查升级（Linux: update-dsh-linux.sh）
```

`scripts/` 下的脚本可从 `~/.dsh` 用 `./init-repo.sh` 同步维护。
