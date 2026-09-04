# Changelog

## Unreleased

### 修复

- 修复 Windows 原生 IKEv2 客户端长时间连接后可能断开的问题。
- 禁用服务端主动发起 CHILD_SA 定时重协商，由 Windows 客户端发起，避免 NAT 后的 Windows 不响应而触发重传超时。
- 将 MODP2048 调整为 IKE proposal 的首选 DH 组，兼容 Windows 的服务端 IKE SA 重协商要求。
- 启动日志增加 `rekey_time` 关键配置输出，方便确认修复已经加载。
- 更新账号改名后的 GitHub 仓库和 GHCR 镜像地址为 `MarmieQi/IKEv2` 与 `ghcr.io/marmieqi/ikev2`。

## v1.2.0 - Official Proxy ARP Mode Release

将当前版本作为正式版。

### 新增与完善

- Proxy ARP 同网段模式正式可用。
- 支持 `PROXYARP_VPN_POOL` 使用 CIDR：
  - `192.168.0.240/28`
- 支持 `PROXYARP_VPN_POOL` 使用 IP 范围：
  - `192.168.0.180-192.168.0.200`
- 由 `start.sh` 根据运行模式直接生成 strongSwan 配置。
- 修复 IP 范围地址池无法写入 iptables 规则的问题。
- NAT 和 Proxy ARP 两套配置可以同时存在，只通过 `VPN_MODE` 选择当前运行模式。
- 支持不同模式独立配置 DNS：
  - `NAT_DNS1` / `NAT_DNS2`
  - `PROXYARP_DNS1` / `PROXYARP_DNS2`
- Proxy ARP 模式支持自动推导：
  - `PROXYARP_LAN_SUBNET`
  - `PROXYARP_DNS1`
- 用大白话补充解释高级字段：
  - `PROXYARP_LAN_SUBNET = 服务端知道你的家里内网范围`
  - `PROXYARP_LOCAL_TS = 告诉客户端哪些目标地址走 VPN`

### 推荐配置

NAT 默认模式：

```env
VPN_MODE=nat
NAT_VPN_POOL=10.66.0.0/24
NAT_DNS1=1.1.1.1
NAT_DNS2=8.8.8.8
```

Proxy ARP 同网段模式：

```env
VPN_MODE=proxyarp
PROXYARP_VPN_POOL=192.168.0.180-192.168.0.200
# PROXYARP_LAN_SUBNET 默认自动推导
# PROXYARP_LOCAL_TS 默认等于 PROXYARP_LAN_SUBNET
```

### 注意事项

- Proxy ARP 地址池必须避开路由器 DHCP 地址池。
- Proxy ARP 地址池不能和已有局域网设备冲突。
- 如果客户端所在地网络和家里内网网段重叠，可能发生路由冲突。
- 默认 Proxy ARP 模式只让家里内网流量走 VPN；如果设置 `PROXYARP_LOCAL_TS=0.0.0.0/0`，则客户端所有 IPv4 流量都会走 VPN。

## v1.1.0 - Independent Mode Configs

新增两种独立运行模式：

### 新增

- 新增 `VPN_MODE=nat` 默认模式。
- 新增 `VPN_MODE=proxyarp` 高级同网段模式。
- `start.sh` 根据 `VPN_MODE` 直接生成对应运行配置。
- NAT 模式自动启用 MASQUERADE。
- Proxy ARP 模式不做 MASQUERADE，并开启 Proxy ARP。
- 新增 `LAN_SUBNET` 和 `VPN_LOCAL_TS` 环境变量。
- README 增加 NAT / Proxy ARP 两种模式教程。

### 说明

- NAT 模式推荐普通用户使用，默认 `VPN_POOL=10.66.0.0/24`。
- Proxy ARP 模式适合同网段 IP 需求，例如 `VPN_POOL=192.168.0.240/28`。
- Proxy ARP 模式必须避开主路由 DHCP 地址池和已有设备 IP。

## v1.0.0 - Official Release

正式可用版本。

### 已验证

- IKEv2 SA 可以成功建立。
- CHILD_SA 可以成功安装。
- Android/Windows IKEv2 EAP-MSCHAPv2 客户端可连接。
- VPN 客户端可以获得 `10.66.0.x` 地址。
- `swanctl --list-sas` 显示 `ESTABLISHED` 和 `INSTALLED`。
- 隧道存在真实 in/out 流量。

### 核心修复

- 安装并启用 `eap-mschapv2` 插件。
- 支持 Android/Windows 常见 IKE proposal。
- IKE 仅使用 SHA-256 与 MODP 4096/2048，ESP 仅使用 AES 与 SHA-256。
- `send_cert = always`，服务端主动发送证书。
- `send_certreq = no`，不向客户端发送证书请求。
- 自动拆分 fullchain：
  - 服务器证书放入 `/etc/swanctl/x509/`
  - 中间证书放入 `/etc/swanctl/x509ca/`
- 启动时打印证书链数量、证书信息和关键 swanctl 配置，方便排查。

### 部署要求

- 宿主机必须支持 XFRM/IPsec。
- Docker 容器必须使用 host network。
- Docker 容器必须使用 privileged。
- `ssl/$VPN_CERT_FILE` 必须是 fullchain。
- `ssl/$VPN_KEY_FILE` 必须与证书匹配。
