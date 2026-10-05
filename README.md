# luci-app-vnt2cli

OpenWrt LuCI 插件，用于管理 VNT2 命令行客户端 `vnt2_cli` 和控制工具 `vnt2_ctrl`。

## 功能

- **插件设置**：单配置文件模型，包含客户端 `.toml` 的全部设置项——网络编号/订阅链接、服务器与直连地址、优先中转、打洞规则、虚拟网卡模式、虚拟 IP、设备信息、MTU、传输优化开关、子网与端口转发、端口映射、加密密码、证书校验、STUN、隧道监听、事件脚本，以及启用开关、控制端口、程序路径、日志级别、下载镜像源。
- **编辑配置**：在"插件设置"内以 TOML 文本查看和编辑当前配置；保存时解析文本写回插件配置（UCI，与表单同源），并由后台重启客户端生效。
- **运行信息**：运行状态、本地/目标版本、运行时长、PID、CPU/内存、下载状态；通过 `vnt2_ctrl` 展示服务器连接、虚拟 IP、节点列表和路由列表。
- **运行日志**：合并客户端日志（`/tmp/logs/vnt2.log`）与下载/后台任务日志（`/tmp/vnt2-download.log`），支持自动刷新和清空。
- **上传程序**：手动上传 `vnt2_cli` 单文件二进制或包含 `vnt2_cli` 的 `.zip` / `.tar.gz` 压缩包（`vnt2_ctrl` 存在于包中时一并安装）。
- **自动下载**：从固定仓库 `vnt-dev/vnt` 的固定版本 `2.0.10` 按设备架构自动下载官方压缩包，安装 `vnt2_cli` 与 `vnt2_ctrl`；支持 gh-proxy、Gitee、GitLab、Cloudflare R2 镜像与自定义镜像回退。
- **虚拟网卡同步**：根据配置的 `device_mode`（no/tun/tap）自动创建或清理 `network.VNT2` 接口、`VNT2` 防火墙区域和四方向转发规则，`no_nat` 控制 MASQUERADE。
- **设备身份持久化**：自动维护 `/etc/machine-id`，设备 ID 跨重启稳定。

## 运行模型

- **单配置文件**：客户端配置只有一个，UCI `/etc/config/vnt2` 是唯一事实来源；主服务在每次启动前将 UCI 配置原子导出为运行时 TOML `/tmp/vnt2cli.toml`，不支持多配置文件。
- `vnt2_cli` 为单实例进程：`/etc/init.d/vnt2` 以工作目录 `/tmp`、`--conf /tmp/vnt2cli.toml` 和显式 `--ctrl-port <端口>` 启动。
- 控制端口默认 `11233`，仅监听 `127.0.0.1`，不做任何防火墙放行。
- 保存应用通过 `/tmp/vnt2-restart.pending` 标记交给后台 worker 完成重启，不阻塞 LuCI 请求。
- 上传安装由独立 upload-worker 完成；下载、网络同步由主服务与 restart-worker 处理。

## 目录与文件

- UCI 配置：`/etc/config/vnt2`（客户端配置唯一事实来源）。
- 运行时 TOML：`/tmp/vnt2cli.toml`（由 init 从 UCI 导出，每次启动重新生成，直接编辑无效）。
- 版本 sidecar：`/etc/config/vnt2-cli.version`（记录最近一次自动下载安装的 tag 与两个二进制的路径/大小/修改时间）。
- 设备 ID 保留清单：`/lib/upgrade/keep.d/vnt2cli`。

## 安装方法

### OpenWrt 24.10.x（IPK）

系统 -> 软件包 -> 上传软件包，安装即可；或通过 SSH：

```sh
opkg install /tmp/luci-app-vnt2cli_*.ipk
```

### OpenWrt 25.12.x（APK）

Release 发布的 `.apk` 由 SDK 自编译构建，未使用官方签名密钥，属于未签名包，安装和后续升级都需要 `--allow-untrusted` 参数。将 APK 上传到路由器 `/tmp/` 后通过 SSH 执行：

```sh
apk add --allow-untrusted /tmp/luci-app-vnt2cli_*.apk
apk info luci-app-vnt2cli
```

LuCI 的软件包上传页面不会自动添加 `--allow-untrusted` 参数，APK 请通过 SSH 安装。若后续使用固定签名密钥构建并发布公钥，则可去掉该参数直接安装升级。


## 卸载方法

OpenWrt 24.10.x：

```sh
opkg remove luci-app-vnt2cli
```

OpenWrt 25.12.x：

```sh
apk del luci-app-vnt2cli
```