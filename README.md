# IKEv2 Docker

基于 Debian 12、strongSwan 的 IKEv2/IPSec 服务端，使用 EAP-MSCHAPv2 用户认证，支持 Windows / Android 客户端。

日常只维护 **`.env` 和 `ssl/`**：域名、网络和用户账号集中在 `.env`，证书单独存放。修改配置后重启容器生效。

## 首次部署

宿主机需安装 Docker 和 Docker Compose，并支持 Linux XFRM/IPsec。路由器将 UDP 500、4500 转发到宿主机；域名指向入口公网地址。

```bash
git clone https://github.com/MarmieQi/IKEv2.git
cd IKEv2
cp .env.example .env
mkdir -p ssl
```

编辑 `.env`，按注释填写域名、模式和至少一组用户。证书放入 `ssl/server.crt`（fullchain）及 `ssl/server.key`；文件名可在 `.env` 修改。
证书 SAN 必须包含 VPN 域名，EKU 应包含 TLS Web Server Authentication。

```bash
chmod 600 .env ssl/server.key
sudo bash install.sh
```

## 修改配置

编辑 `.env` 后执行：

```bash
docker compose restart
```

NAS 界面点击“重启容器”也可以。修改账号或证书后同样重启，VPN 客户端需要重新连接。
Compose 的挂载、网络等容器创建参数发生变化时，仍需 `docker compose up -d --force-recreate`。

## 更新程序

```bash
git pull --ff-only
docker compose pull
docker compose up -d --force-recreate --pull never
```

程序来自镜像；仅 `git pull` 或重启容器不会安装新镜像。构建由 GitHub Actions 自动完成，发布到 `ghcr.io/marmieqi/ikev2:latest`。

## 旧配置迁移

旧 `.env` 参数和 `config/users.txt` 仍兼容，可以先更新镜像，不必立即改配置。
要合并为一份带完整注释的 `.env`，更新代码后在部署目录执行：

```bash
bash scripts/migrate-config.sh
```

脚本将当前生效的 DNS、路由、地址池、网关和账号写入新格式，并先备份旧 `.env` 为 `.env.backup.*`。
原账号文件不自动删除；确认新配置及账号正常后，清空旧 `config/users.txt` 中的有效账号，避免以后删除所有 `USER_*` 时恢复旧账号。
迁移时把当前模式的 DNS 和路由保留为公共设置；以后切换模式仍使用这组公共设置。
更新镜像后重建一次容器，以后修改配置继续只需重启。不要直接用模板覆盖已有 `.env`。

## 配置示例

完整注释见 [.env.example](.env.example)，详细规则与旧参数映射见 [配置说明](docs/configuration.md)。
以下为 Proxy ARP 通过同局域网旁路由上网的示例，域名及账号需要替换：

```env
VPN_DOMAIN=vpn.example.com
VPN_MODE=proxyarp
VPN_CERT_FILE=server.crt
VPN_KEY_FILE=server.key

VPN_DNS=218.6.200.139,61.139.2.69
VPN_ROUTES=0.0.0.0/0

PROXYARP_POOL=192.168.0.201-192.168.0.210
PROXYARP_LAN=192.168.0.0/24
PROXYARP_GATEWAY=192.168.0.4

USER_1_NAME=user1
USER_1_PASSWORD='replace-with-your-password'
```

Proxy ARP 地址池需排除 DHCP 和已有设备，不能包含 LAN 网络地址或广播地址。旁路由需支持转发及出口 NAT/回程。
客户端访问 LAN 仍直连，非 LAN 的 VPN 流量交给旁路由；宿主机默认网关不变。
`VPN_ROUTES=0.0.0.0/0` 允许全部 IPv4 目标进入隧道，客户端也必须开启全隧道。

## 客户端

- Android：选择 IKEv2/IPSec MSCHAPv2，服务器及 IPSec 标识符填写 `VPN_DOMAIN`，使用 `.env` 中的账号密码。
- Windows：添加 IKEv2 连接，使用用户名和密码登录。需要全局上网时在管理员 PowerShell 执行：

```powershell
Set-VpnConnection -Name "你的 VPN 连接名称" -SplitTunneling $false
```

## 查看运行情况

```bash
docker compose ps -a
docker compose logs --tail=100
docker compose logs -f --tail=50
docker exec ikev2-mschapv2 swanctl --list-sas
```

日志显示 `已读取运行配置`、`账号来源: .env`，表示新配置已加载；启用旁路由时会显示网关及 LAN 网卡。
连接成功后应能看到 `IKE_SA ... established` 和 `CHILD_SA ... established`。日志中可能包含用户名和网络地址，分享前按需遮盖。

## 目录结构

```text
IKEv2/
├── .env.example                 # 带注释的统一配置模板
├── .env                         # 本地实际配置及账号，不进 Git
├── docker-compose.yml           # 容器部署
├── Dockerfile                   # 镜像构建及实际解析测试
├── install.sh                   # 首次部署入口
├── scripts/
│   ├── start.sh                 # 容器启动与生命周期
│   ├── migrate-config.sh        # 旧配置合并及备份
│   └── lib/
│       ├── runtime-config.sh    # .env 解析与配置项检查
│       ├── network-config.sh    # 模式、默认值和旧参数归一化
│       ├── users.sh             # 统一账号读取及认证配置
│       ├── strongswan.sh        # 生成连接配置
│       └── proxyarp.sh          # ARP 与旁路由策略路由
├── config/
│   ├── strongswan.conf          # 镜像内部静态配置
│   └── users.txt                # 仅为旧部署兼容保留
├── ssl/                         # 本地证书与私钥，不进 Git
├── docs/configuration.md        # 参数、默认值及兼容规则
└── tests/                       # 配置、迁移、路由和实际解析测试
```

## 开发验证

```bash
sudo bash tests/run.sh
```

路由测试使用独立网络命名空间，不更改宿主机网络。镜像构建还会使用镜像内的 strongSwan 实际解析 NAT、Proxy ARP 和包含特殊字符的账号配置。
这些检查不替代真实客户端、NAS 和旁路由的连通性测试。
