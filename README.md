# IKEv2 Docker

这是一个基于 **Debian + strongSwan + swanctl** 的 Docker IKEv2/IPSec 服务端项目，目标是部署安卓/Windows 原生可用的：

```text
IKEv2/IPSec MSCHAPv2
```

当前已验证：

```text
IKEv2 SA ESTABLISHED
CHILD_SA INSTALLED
TUNNEL-in-UDP
EAP-MSCHAPv2 用户认证成功
真实流量 in/out 正常
```

---

## 核心变化

账号不再写在 `.env` 里。

本项目现在统一使用：

```text
config/users.txt
```

作为 VPN 账号文件。每行一个账号：

```text
用户名:密码
```

仓库默认提供带注释说明的 `config/users.txt`。填写真实账号后，不要将该文件的改动提交到 GitHub。

---

## 两种运行模式

项目支持两种互相独立的运行模式：

```text
nat       默认模式，VPN 客户端使用独立网段，例如 10.66.0.0/24，并通过 NAT 访问内网/外网。
proxyarp  高级模式，VPN 客户端使用局域网同网段 IP，例如 192.168.0.240/28，不做 NAT，通过 Proxy ARP 暴露给 LAN。
```

启动脚本会根据 `.env` 里的：

```env
VPN_MODE=nat
# 或
VPN_MODE=proxyarp
```

启动脚本根据 `VPN_MODE` 计算地址池、DNS、流量选择器和防火墙规则，并直接生成 strongSwan 运行配置。

---

## 目录结构

推荐部署目录：

```text
/vol1/1000/docker/ikev2
├── ssl                # 唯一证书目录
│   ├── server.crt     # 默认 fullchain，服务器证书 + 中间证书
│   └── server.key     # 默认私钥
├── config
│   └── users.txt       # 本地 VPN 账号文件，不提交 GitHub
├── start.sh            # 容器启动和运行配置生成脚本
├── strongswan.conf     # strongSwan 静态配置
├── docker-compose.yml
├── Dockerfile
├── install.sh
├── .env.example
└── README.md
```

证书要求：

```text
ssl/$VPN_CERT_FILE 必须是 fullchain
ssl/$VPN_KEY_FILE 必须和证书匹配
证书 SAN 必须包含 VPN_DOMAIN，例如 DNS:vpn.example.com
证书 EKU 需要包含 TLS Web Server Authentication
```

证书文件名由 `.env` 中的 `VPN_CERT_FILE` 和 `VPN_KEY_FILE` 指定，默认是：

```env
VPN_CERT_FILE=server.crt
VPN_KEY_FILE=server.key
```

本项目启动脚本会自动把配置的 fullchain 拆分为：

```text
服务器证书 -> /etc/swanctl/x509/cert.pem
中间证书 -> /etc/swanctl/x509ca/chain-01.pem
```

---

## 前提条件

宿主机必须支持 Linux XFRM/IPsec：

```bash
modprobe xfrm_user
modprobe xfrm_interface
modprobe esp4
modprobe esp6
modprobe xfrm_algo

ip xfrm state
ip xfrm policy
```

`ip xfrm state` 和 `ip xfrm policy` 不报错即可。

部分内核没有启用 `CONFIG_XFRM_STATISTICS`，所以 `/proc/net/xfrm_stat` 不存在不一定是问题。

---

## 从零部署

在 NAS 或 Linux 宿主机执行：

```bash
mkdir -p /vol1/1000/docker/ikev2
cd /vol1/1000/docker/ikev2

git clone https://github.com/MarmieQi/IKEv2.git .
```

克隆完成后，仓库已经包含带注释示例的 `config/users.txt`。

容器镜像由 GitHub Actions 构建并发布为 `ghcr.io/marmieqi/ikev2:latest`。部署机只会拉取镜像，不会在本地执行 Dockerfile 构建。

复制并编辑 `.env`：

```bash
cp .env.example .env
nano .env
```

默认 NAT 模式配置：

```env
VPN_MODE=nat
VPN_DOMAIN=vpn.example.com

NAT_VPN_POOL=10.66.0.0/24
NAT_DNS1=1.1.1.1
NAT_DNS2=8.8.8.8
# NAT_LOCAL_TS=0.0.0.0/0
```

填写账号文件：

```bash
nano config/users.txt
chmod 600 config/users.txt
```

默认文件只有注释示例；未填写至少一个有效账号时，`install.sh` 会停止部署。

账号文件就是账号和密码，两项之间用英文冒号 `:` 分隔：

```text
# 用户名:密码
user1:password1
user2:password2
user3:password3
```

放证书：

```bash
mkdir -p ssl
```

```text
/vol1/1000/docker/ikev2/ssl/server.crt
/vol1/1000/docker/ikev2/ssl/server.key
```

如果证书文件名不同，只需修改 `.env`：

```env
VPN_CERT_FILE=my-vpn.crt
VPN_KEY_FILE=my-vpn.key
```

启动：

```bash
chmod +x install.sh
./install.sh
```

---

## 多账号配置

`config/users.txt` 是唯一账号来源。

格式：

```text
用户名:密码
```

也就是：

```text
账号:密码
```

规则：

```text
每行一个账号
空行会被忽略
# 开头的注释行会被忽略
用户名不能为空
密码不能为空
密码里可以包含冒号，脚本只按第一个冒号切分用户名和密码
```

示例：

```text
user1:password1
user2:password2
user3:password3
```

如果只需要一个账号，只写一行即可：

```text
user1:password1
```

启动脚本会自动生成 strongSwan `swanctl.conf` 里的：

```text
secrets {
    eap-user-1 { ... }
    eap-user-2 { ... }
    eap-user-3 { ... }
}
```

然后通过 `swanctl --load-all` 加载。

注意：

```text
config/users.txt 包含明文密码
仓库中的 config/users.txt 默认只有注释示例
填写真实账号后，不要把改动提交到 GitHub
```

---

## NAT 模式

适合普通远程访问，推荐默认使用。

`.env` 示例：

```env
VPN_MODE=nat
VPN_DOMAIN=vpn.example.com

NAT_VPN_POOL=10.66.0.0/24
NAT_DNS1=1.1.1.1
NAT_DNS2=8.8.8.8
# NAT_LOCAL_TS=0.0.0.0/0
```

特点：

```text
VPN 客户端拿 10.66.0.x
容器自动做 MASQUERADE/NAT
VPN 客户端可以访问部署 IKEv2 这台机器自己的所有服务
不需要修改主路由静态路由
最稳定，不容易和局域网 DHCP 冲突
```

---

## Proxy ARP 同网段模式

高级模式，让 VPN 客户端拿局域网同网段 IP。

假设局域网是：

```text
路由器：192.168.0.1
FnNas：192.168.0.2
LAN：192.168.0.0/24
```

建议在主路由 DHCP 里预留一小段不分配，例如：

```text
192.168.0.240 - 192.168.0.254
```

`.env` 示例：

```env
VPN_MODE=proxyarp
VPN_DOMAIN=vpn.example.com

# 二选一：CIDR 网段
PROXYARP_VPN_POOL=192.168.0.240/28

# 或者使用连续 IP 范围
# PROXYARP_VPN_POOL=192.168.0.200-192.168.0.210

# PROXYARP_LAN_SUBNET=192.168.0.0/24
# PROXYARP_LOCAL_TS=192.168.0.0/24
# PROXYARP_DNS1=192.168.0.1
# PROXYARP_DNS2=1.1.1.1
```

`PROXYARP_VPN_POOL` 只接受一个 CIDR 网段，或一个“起始 IP-结束 IP”连续范围。不支持多个网段、逗号列表或带空格的值。

特点：

```text
VPN 客户端拿 192.168.0.240/28 里的地址
不做 MASQUERADE/NAT
宿主机开启 Proxy ARP
局域网设备可以看到 VPN 客户端同网段源 IP
VPN 客户端可以访问部署 IKEv2 这台机器自己的所有服务
```

安全要求：

```text
不要使用整个 192.168.0.0/24 作为 PROXYARP_VPN_POOL
PROXYARP_VPN_POOL 必须避开主路由 DHCP 地址池
PROXYARP_VPN_POOL 必须避开已有设备 IP
如果客户端所在地网络也是 192.168.0.0/24，可能发生路由冲突
```

---

## 安卓配置

VPN 类型：

```text
IKEv2/IPSec MSCHAPv2
```

填写：

```text
服务器地址：vpn.example.com
IPSec 标识符：vpn.example.com
用户名：config/users.txt 里的用户名
密码：config/users.txt 对应用户的密码
```

注意：

```text
服务器地址和 IPSec 标识符必须和证书域名一致
不要填写 IP
不要选择 PSK
不要填写预共享密钥
```

---

## Windows 配置

使用 Windows 系统自带的 VPN 客户端，不需要修改注册表，也不需要运行 PowerShell 设置算法。

打开“设置 → 网络和 Internet → VPN → 添加 VPN”，填写：

```text
VPN 提供商：Windows（内置）
连接名称：IKEv2 VPN
服务器名称或地址：vpn.example.com
VPN 类型：IKEv2
登录信息的类型：用户名和密码
用户名：config/users.txt 里的用户名
密码：config/users.txt 对应用户的密码
```

服务端会优先协商 AES/SHA-256/MODP2048 或更强算法，并保留 Windows 10/11 原生 IKEv2 默认算法所需的回退提案。

为避免 Windows 客户端位于 NAT 后时不响应服务端主动发起的 CHILD_SA 重协商，本项目禁用服务端的 CHILD_SA 定时重协商，由 Windows 客户端按自身策略发起。IKE SA 仍会正常定时重协商，并将 MODP2048 放在服务端首选位置以兼容 Windows。

参考：[Microsoft Windows IKEv2 默认加密设置](https://learn.microsoft.com/windows/security/operating-system-security/network-security/vpn/how-to-configure-diffie-hellman-protocol-over-ikev2-vpn-connections)、[strongSwan Windows 客户端互操作文档](https://docs.strongswan.org/docs/latest/interop/windowsClients.html)。

---

## 端口转发

上级路由器需要把下面端口转发到 FnNas：

```text
UDP 500
UDP 4500
```

---

## 查看日志

```bash
docker logs -f ikev2-mschapv2
```

启动成功时应看到类似：

```text
运行模式: nat
VPN_POOL: 10.66.0.0/24
VPN_LOCAL_TS: 0.0.0.0/0
VPN_USERS_FILE: /etc/ikev2/users.txt
已加载 EAP 账号数量: 3
允许 VPN 客户端访问本机服务: 10.66.0.0/24
证书链数量: 2
loaded certificate 'CN=vpn.example.com'
loaded certificate 'C=US, O=DigiCert Inc ...'
loaded EAP shared key with id 'user1'
loaded connection 'ikev2-mschapv2'
```

Proxy ARP 模式应看到：

```text
运行模式: proxyarp
VPN_POOL: 192.168.0.240/28
LAN_SUBNET: 192.168.0.0/24
允许 VPN 客户端访问本机服务: 192.168.0.240/28
应用 Proxy ARP 模式防火墙规则: 不做 MASQUERADE
```

---

## 查看在线连接

```bash
docker exec -it ikev2-mschapv2 swanctl --list-sas
```

成功连接时应看到：

```text
ikev2-mschapv2: ESTABLISHED, IKEv2
net: INSTALLED, TUNNEL-in-UDP
remote 10.66.0.x/32
in/out bytes 正常增长
```

Proxy ARP 模式则会看到：

```text
remote 192.168.0.24x/32
```

---

## 停止

```bash
docker compose down
```

---

## 更新

```bash
cd /vol1/1000/docker/ikev2

git pull

docker compose down
docker compose pull
docker compose up -d
```

---

## 常见问题

### 1. `unable to create netlink socket`

说明容器或宿主机无法访问 XFRM。检查：

```bash
modprobe xfrm_user
modprobe xfrm_interface
modprobe esp4
modprobe esp6
ip xfrm state
```

Docker 必须使用：

```yaml
network_mode: host
privileged: true
```

### 2. `no shared key found`

说明客户端选成了 PSK 模式。

请改成：

```text
IKEv2/IPSec MSCHAPv2
```

不要选：

```text
IKEv2/IPSec PSK
IPSec Xauth PSK
```

### 3. `loading EAP_MSCHAPV2 method failed`

说明镜像缺少或未加载 `eap-mschapv2` 插件。

GitHub 发布的镜像会安装并启用：

```text
libstrongswan-eap-mschapv2.so
```

检查：

```bash
docker exec -it ikev2-mschapv2 sh -c 'find /usr/lib /lib -name "*mschap*" 2>/dev/null'
```

### 4. 连接卡在 `EAP/REQ/ID`

重点检查证书链。`ssl/$VPN_CERT_FILE` 必须是 fullchain，且脚本会拆分为服务器证书和中间证书。

检查：

```bash
grep -c "BEGIN CERTIFICATE" "ssl/$VPN_CERT_FILE"
openssl x509 -in "ssl/$VPN_CERT_FILE" -noout -subject -issuer -dates -ext subjectAltName -ext extendedKeyUsage
```

### 5. `找不到账号文件 /etc/ikev2/users.txt`

说明默认的 `config/users.txt` 缺失，或者 `docker-compose.yml` 没有正确挂载。

检查：

```bash
ls -l config/users.txt
docker compose config | grep users.txt
```

重新填写：

```bash
nano config/users.txt
chmod 600 config/users.txt
```

### 6. `账号文件存在无效行`

说明 `config/users.txt` 里有一行不是 `用户名:密码` 格式。

正确示例：

```text
user1:password1
user2:password2
```

错误示例：

```text
user1
:password1
user1:
```

### 7. 能访问局域网其他设备，但不能访问 IKEv2 宿主机自己的服务

访问局域网其他设备通常走 `FORWARD` 链；访问部署 IKEv2 这台机器自己的服务走 `INPUT` 链。

本项目启动脚本会自动放行 VPN 地址池到本机服务：

```text
允许 VPN 客户端访问本机服务: <VPN_POOL>
```

如果仍然无法访问，检查服务是否只监听了 `127.0.0.1`：

```bash
ss -lntup
```

如果看到服务只监听：

```text
127.0.0.1:端口
```

需要把服务改成监听：

```text
0.0.0.0:端口
```

或者监听宿主机 LAN IP。

如果服务是 Docker 容器，还要确认端口没有只绑定到 `127.0.0.1`。

### 8. NAT 模式能连接但不能上网

检查 IPv4 转发和 NAT：

```bash
sysctl net.ipv4.ip_forward
iptables -t nat -S | grep 10.66
```

### 9. Proxy ARP 模式同网段不通

检查：

```bash
cat /proc/sys/net/ipv4/conf/all/proxy_arp
ip neigh show
iptables -S FORWARD
iptables -S INPUT
```

同时确认：

```text
PROXYARP_VPN_POOL 没有和 DHCP 地址池冲突
PROXYARP_VPN_POOL 没有和已有设备 IP 冲突
客户端所在地网络没有和家里 LAN 网段重叠
```

### 10. Windows 连接一段时间后自动断开

如果日志出现：

```text
creating rekey job for CHILD_SA
generating CREATE_CHILD_SA request
retransmit 1 of request
...
giving up after 5 retransmits
lease ... went offline
```

说明服务端主动发起 CHILD_SA 重协商后没有收到 Windows 响应。strongSwan 官方指出，位于 NAT 后的 Windows 客户端可能不接受服务端主动发起的 CHILD_SA 重协商。

本项目已按官方建议设置：

```text
rekey_time = 0
```

这只禁用服务端主动发起 CHILD_SA 重协商，Windows 客户端仍可主动发起重协商。更新镜像并重启容器后，可在启动日志的“关键 swanctl 配置”中确认该设置已经加载。

---

## 已验证成功日志

成功连接后示例：

```text
ikev2-mschapv2: ESTABLISHED, IKEv2
remote 'vpn.example.com' @ x.x.x.x EAP: 'user1' [10.66.0.1]
net: INSTALLED, TUNNEL-in-UDP
in/out packets 正常增长
```
