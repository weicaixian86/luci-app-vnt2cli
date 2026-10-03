# luci-app-vnt2cli

OpenWrt LuCI 插件，用于管理 VNT2 命令行客户端 `vnt2_cli` 和控制工具 `vnt2_ctrl`。

## 功能

- **基本设置**：启用/禁用客户端、选择启用配置文件、控制端口、程序路径、日志级别、下载镜像源。
- **配置管理**：在 `/vnt_config/` 下新建、编辑、删除 TOML 配置文件，并一键切换启用配置。
- **运行状态**：运行状态、本地/目标版本、运行时长、PID、CPU/内存、下载状态；通过 `vnt2_ctrl` 展示服务器连接、虚拟 IP、节点列表和路由列表。
- **运行日志**：合并客户端日志（`/tmp/logs/vnt2.log`）与下载/后台任务日志（`/tmp/vnt2-download.log`），支持自动刷新和清空。
- **上传程序**：手动上传 `vnt2_cli` 单文件二进制或包含 `vnt2_cli` 的 `.zip` / `.tar.gz` 压缩包（`vnt2_ctrl` 存在于包中时一并安装）。
- **自动下载**：从固定仓库 `vnt-dev/vnt` 的固定版本 `2.0.10` 按设备架构自动下载官方压缩包，安装 `vnt2_cli` 与 `vnt2_ctrl`；支持 gh-proxy、Gitee、GitLab、Cloudflare R2 镜像与自定义镜像回退。
- **虚拟网卡同步**：根据启用配置的 `device_mode`（no/tun/tap）自动创建或清理 `network.VNT2` 接口、`VNT2` 防火墙区域和四方向转发规则，`no_nat` 控制 MASQUERADE。
- **设备身份持久化**：自动维护 `/etc/machine-id`，设备 ID 跨重启稳定。

## 运行模型

- `vnt2_cli` 为单实例进程：`/etc/init.d/vnt2` 以工作目录 `/tmp`、绝对路径 `--conf /vnt_config/<conf_file>` 和显式 `--ctrl-port <端口>` 启动。
- 控制端口默认 `11233`，仅监听 `127.0.0.1`，不做任何防火墙放行。
- 保存应用通过 `/tmp/vnt2-restart.pending` 标记交给后台 worker 完成重启，不阻塞 LuCI 请求。
- 上传安装由独立 upload-worker 完成；下载、网络同步由主服务与 restart-worker 处理。

## 目录与文件

- 运行时配置目录：`/vnt_config/*.toml`（首次安装为空，不创建任何默认 TOML）。
- UCI 配置：`/etc/config/vnt2`。
- 版本 sidecar：`/etc/config/vnt2-cli.version`（记录最近一次自动下载安装的 tag 与两个二进制的路径/大小/修改时间）。
- 设备 ID 保留清单：`/lib/upgrade/keep.d/vnt2cli`。

## 编译

- OpenWrt 24.10.x SDK 输出 `.ipk`，25.12.x SDK 输出 `.apk`；安装包架构无关（`-all`），运行时按设备架构自动下载对应二进制。
- 使用 GitHub Actions 页面的 `Build Release` 工作流手动触发，输入 Release tag 与可选描述；产物命名固定为 `luci-app-vnt2cli_<版本>-all.ipk` 与 `luci-app-vnt2cli_<版本>-all.apk`。
- 本地检查：`tests/validate-source.sh`（Shell 语法、Lua 语法、YAML、UTF-8/BOM、包名与固定版本门禁）。

## 依赖

`luci-base`、`luci-compat`、`kmod-tun`、`curl`、`ca-bundle`、`unzip`、`jsonfilter`。
