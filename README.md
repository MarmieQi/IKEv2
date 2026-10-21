# IKEv2 Docker

基于 Debian 12、strongSwan 的 IKEv2/IPSec 服务端，使用 EAP-MSCHAPv2 认证，支持 Windows / Android 客户端。

日常只维护三处：`.env` 配置服务和网络，`config/users.txt` 管理账号，`ssl/` 放证书。修改后重启容器生效。
账号可填写明文密码，容器启动时自动转换为 NT 哈希并写回账号文件。

## 首次部署

宿主机需安装 Docker 和 Docker Compose，并支持 Linux XFRM/IPsec。路由器将 UDP 500、4500 转发到宿主机，域名指向公网入口。

```bash
git clone https://github.com/MarmieQi/IKEv2.git
cd IKEv2
cp .env.example .env
cp config/users.example config/users.txt
mkdir -p ssl
```

按各文件注释填写配置和账号。证书放入 `ssl/server.crt`（fullchain）及 `ssl/server.key`；文件名可在 `.env` 修改。
证书 SAN 必须包含 VPN 域名，EKU 应包含 TLS Web Server Authentication。

```bash
chmod 600 .env config/users.txt ssl/server.key
sudo bash install.sh
```

## 配置示例

完整注释见 [.env.example](.env.example)，参数说明见 [配置文档](docs/configuration.md)。
以下为通过家里旁路由上网的示例，域名需替换：

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
```

地址池需排除 DHCP 和已有设备，不能包含 LAN 网络地址/广播地址。旁路由需允许转发及出口 NAT/回程。
客户端访问 LAN 仍直连，非 LAN 的 VPN 流量交给旁路由，宿主机默认网关不变。
`VPN_ROUTES=0.0.0.0/0` 允许全部 IPv4 目标进入隧道，客户端也必须开启全隧道。

## 用户账号

编辑 `config/users.txt`，每行一个账号：

```text
alice:plain:你的密码
bob:plain:另一个密码
```

启动或重启容器后，`plain` 行自动替换为 `用户名:nt:32位NT哈希`。客户端仍输入原始密码，不填写哈希。
修改密码时将该用户整行改回 `用户名:plain:新密码`，然后重启。禁用/删除用户时注释或删除对应行，再重启。
密码取第二个冒号后的全部内容，不要额外加引号。完整规则见 [账号模板](config/users.example)。

这里使用 strongSwan 官方支持的 NT 哈希，即 `MD4(UTF-16LE(password))`，并通过 `ntlm` 凭据加载。
这是哈希存储，不是可逆加密；NT 哈希仍是敏感凭据，文件权限为 `600`，不要上传或提交 Git。
转换采用文件锁和原子替换；配置错误、转换失败或检测到并发编辑时不覆盖原文件，不生成明文备份。
运行时生成的 strongSwan 配置也只包含哈希，不保存明文密码。

## 修改配置

修改 `.env`、账号或证书后执行：

```bash
docker compose restart
```

NAS 界面点“重启容器”也可以，客户端需要重新连接。
`config/` 必须可写挂载，供启动脚本写回账号哈希；不要将账号文件单独只读挂载。
Compose 的挂载、网络等容器创建参数发生变化时，仍需重新创建容器。

## 更新程序

```bash
git pull --ff-only
docker compose pull
docker compose up -d --force-recreate --pull never
```

程序来自镜像，仅 `git pull` 或重启容器不会安装新镜像。
GitHub Actions 构建并发布 `ghcr.io/marmieqi/ikev2:latest`。

本版只支持新配置格式，不兼容旧参数和旧账号格式，也不提供自动迁移逻辑。
旧部署升级前自行保存当前配置和账号，再按新模板填写 `.env` 和 `config/users.txt`，并更新镜像、重建容器一次。
如果旧 `users.txt` 被 Git 跟踪且有本地修改，先将其备份并移出该路径，再执行 `git pull`，避免文件删除冲突。
实际账号文件现在由 Git 忽略，仓库只包含 `users.example` 模板。

## 客户端

- Android：选择 IKEv2/IPSec MSCHAPv2，服务器及 IPSec 标识符填写 `VPN_DOMAIN`，使用账号文件中配置的用户名和原始密码。
- Windows：添加 IKEv2 连接，使用用户名和密码登录。全局上网需在管理员 PowerShell 执行：

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

启动日志显示 `已读取运行配置`、`已加载账号数量`；启用旁路由时显示网关和 LAN 网卡。
包含明文账号时会显示已转换并写回的提示。日志不打印密码或哈希。

## 目录结构

```text
IKEv2/
├── .env.example                 # 带中文注释的服务与网络配置模板
├── .env                         # 本地实际配置，不进 Git
├── docker-compose.yml           # 容器部署
├── Dockerfile                   # 镜像构建
├── install.sh                   # 首次部署入口
├── scripts/
│   ├── start.sh                 # 容器启动与生命周期
│   └── lib/
│       ├── runtime-config.sh    # .env 解析及参数检查
│       ├── network-config.sh    # 网络模式与默认值
│       ├── users.sh             # 账号校验、NT 哈希和原子写回
│       ├── strongswan.sh        # 生成连接配置与哈希凭据
│       └── proxyarp.sh          # ARP 与旁路由策略路由
├── config/
│   ├── strongswan.conf          # 镜像内部静态配置
│   ├── users.example            # 带注释的账号模板
│   └── users.txt                # 本地账号和 NT 哈希，不进 Git
├── ssl/                         # 本地证书与私钥，不进 Git
├── docs/configuration.md        # 参数与账号规则
└── tests/                       # 配置、账号和路由测试
```

## 开发验证

```bash
sudo bash tests/run.sh
```

测试覆盖配置校验、已知 NT 哈希向量、密码写回/重置、失败与并发编辑保护，以及隔离网络命名空间内的路由选择。
镜像构建还会用镜像内的 strongSwan 实际解析 NAT、Proxy ARP 和 NTLM 凭据配置。
这些检查不替代实际客户端和旁路由的连通性测试。
