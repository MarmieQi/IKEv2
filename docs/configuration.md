# 配置说明

`.env` 只配置服务与网络，`config/users.txt` 只管理账号。两者修改后重启容器生效。
本版只支持此处列出的配置，不保留旧参数别名、环境变量账号或账号迁移逻辑。

## .env 规则

- 使用 `KEY=VALUE`；空行和 # 开头的注释会忽略，一个配置项只能出现一次。
- 支持 UTF-8（含 BOM）及 Windows CRLF，不支持多行值。
- 单/双引号内保留空格、冒号和 #；可转义外层引号与反斜杠，其他反斜杠序列按字面保留。
- 不执行 Shell 命令，不展开 `${变量}`。这与 Compose 自身的 .env 插值机制不同。
- 不认识的 VPN/NAT/PROXYARP/USER 配置会报错，避免拼写错误被静默忽略。
- 其他变量如 COMPOSE_PROJECT_NAME 可以由 Compose 使用，不导入 VPN 进程。
- 每次启动从文件重新读取；删除或注释配置会恢复默认，不保留容器创建时的旧值。

| 参数 | 作用 | 未填写/留空时 |
|---|---|---|
| `VPN_DOMAIN` | 连接域名及服务器身份 | 必填 |
| `VPN_MODE` | `nat` / `proxyarp` | `nat` |
| `VPN_CERT_FILE` | ssl/ 内的 fullchain 文件名 | `server.crt` |
| `VPN_KEY_FILE` | ssl/ 内的私钥文件名 | `server.key` |
| `VPN_DNS` | 逗号分隔的 IPv4 DNS 地址 | NAT：1.1.1.1,8.8.8.8；Proxy ARP：池所在 /24 的 .1 和 1.1.1.1 |
| `VPN_ROUTES` | 逗号分隔的 IPv4 目标 CIDR | NAT：0.0.0.0/0；Proxy ARP：LAN 网段 |
| `NAT_POOL` | NAT 客户端地址池 | 10.66.0.0/24 |
| `PROXYARP_POOL` | 同 LAN 的客户端地址池 | 192.168.0.201-192.168.0.210 |
| `PROXYARP_LAN` | 家里 LAN 网段 | 根据池推导 /24 |
| `PROXYARP_GATEWAY` | 非 LAN VPN 流量的下一跳 | 使用宿主机原有路由 |

DNS 和路由列表不能含空格或空列表项，目前只支持 IPv4。
网关不会自动改变 DNS 或自动启用全隧道。实际 LAN 不是 /24 或 DNS 不在 .1 时应手动填写。

## 账号与密码

从 `config/users.example` 复制出 `config/users.txt`，每行一个用户：

```text
alice:你的密码
bob:可包含冒号:以及 # 空格和引号
```

- 用户名仅限英文字母、数字、下划线、点、@ 和连字符，不得重复。
- 第一个冒号后的全部内容都是密码，不做变量替换、去空格或引号解析；不要额外包引号。
- 密码不能为空或含回车/换行。文件支持 UTF-8 和 CRLF。
- 空行和 # 开头的注释忽略；通过注释整行禁用账号。
- 只需填写 `用户名:密码`，不填写密码类型；`{NT}` 是程序保存哈希的保留前缀，不用于明文密码。

容器启动时把明文密码转换成 NT 哈希，原子替换文件内容：

```text
alice:{NT}32位十六进制NT哈希
```

已有 `{NT}` 哈希不会重复计算。密码重置时将该行改回 `alice:新密码`，然后重启容器。
客户端始终输入原始密码。删除或禁用账号后需要重启，现有 VPN 连接会随重启断开。

EAP-MSCHAPv2 需要 NT 哈希 `MD4(UTF-16LE(password))`，因此不能直接改用 bcrypt/Argon2 等哈希。
strongSwan 使用 `ntlm` 类型凭据及 `secret = 0x...` 加载 NT 哈希，运行配置不保存明文密码。
这不是可逆加密，哈希本身仍是敏感凭据，账号文件、锁及临时文件权限均为 600。

启动使用同目录锁文件（最长等待 10 秒），完成全文件校验后才写回；转换失败或检测到编辑变动时不覆盖原文件。
写回采用同目录临时文件和原子重命名，不生成明文备份；config/ 必须可写且使用目录挂载。
不要同时启动多个服务实例共享同一份账号文件。编辑器若恰好在最终检查与替换之间保存，仍可能产生竞争，应在修改完成后再重启。
实际 users.txt、锁、临时文件和账号备份由 Git 及 Docker 构建上下文忽略。

## 加密算法与客户端兼容

算法策略统一放在 `scripts/lib/strongswan.sh`，不增加需要日常维护的 `.env` 参数。

- IKE 握手优先 AES-128-CBC / SHA-256 / MODP2048，另外提供 AES-128-GCM / PRF-SHA-256 和 ECP256 组合。
- ESP 数据传输按 AES-128-CBC / SHA-256、AES-128-GCM、AES-256-CBC / SHA-256、AES-256-GCM 的顺序协商。
- 所有原有组合均保留，包括 SHA-1、MODP1024 和 3DES，供现有客户端回退。这些旧选项保留兼容性，不代表现代算法的安全水平。
- 不要求现有 Windows 客户端修改策略；默认提案较旧的客户端仍可能协商到旧组合。仅调整服务器排序不能让客户端使用其未提供的算法。
- GCM 使用 128 位认证标签，不叠加单独的 SHA 完整性算法。ESP 不额外增加 DH 组，保留现有客户端发起重协商的行为。

J1900 不支持 AES-NI，AES-128-CBC / SHA-256 是兼顾兼容性的保守首选；此排序未经该宿主机吞吐测试，不能保证 CBC 比 GCM 更快。
只协商并使用一个组合，不会同时执行列表中的全部算法。支持双方哪些组合、宿主机内核的算法支持决定最终结果。

运行后可查看实际协商结果：

```bash
docker exec ikev2-mschapv2 swanctl --list-sas
```

查看连接的 IKE 和 CHILD_SA 算法；实际业务吞吐主要取决于 CHILD_SA 的 ESP 算法。
这是程序内置策略变更，部署时需要更新镜像并重新创建容器；仅重启旧镜像不会获得新算法配置。

依据：[strongSwan 算法提案与选择顺序](https://docs.strongswan.org/docs/latest/config/proposals.html)、[Windows 默认提案及重协商兼容说明](https://docs.strongswan.org/docs/latest/interop/windowsClients.html)、[Intel J1900 规格](https://www.intel.cn/content/www/cn/zh/products/sku/78867/intel-celeron-processor-j1900-2m-cache-up-to-2-42-ghz/specifications.html)。

## Proxy ARP 与旁路由

池必须完全属于 LAN，避开 DHCP、现有设备、宿主机和 LAN 网络地址/广播地址。
192.168.0.0/24 LAN 可以使用 192.168.0.201-192.168.0.210 或 192.168.0.240/29，不要包含 .255。
网关必须直接可达、在 LAN 内且不在池内，不能是宿主机自身。旁路由需支持转发及上网 NAT/回程。

模块精确匹配客户端源地址池，使用表 20162、协议标记 186、优先级 219，先于 strongSwan 默认的 220 规则；本机交付仍优先。
检测到外部规则占用时拒绝启动，不修改宿主机默认路由或 strongSwan 的 220 表。
正常退出及下次启动时清理本模块规则；强制终止后的残留会在下次启动清理。
网关功能关闭宿主机 all 及网关网卡的 send_redirects，停止后保留该设置。
farp 代答在线客户端的 ARP，使 LAN 回包交给 VPN 服务器。

```bash
ip -4 rule show
ip -4 route show table 20162
ip -4 route show table 220
```

自定义宿主机策略路由时需检查更高优先级规则。远程网络与家里网段重叠仍可能冲突。
同网段虚拟地址不等同二层桥接，广播、组播及设备自动发现不保证可用。

## 防火墙与服务生命周期

项目使用 `IKEV2_INPUT`、`IKEV2_FORWARD`、`IKEV2_POSTROUTING` 专属链，及带 `ikev2-managed-v1` 标记的跳转规则。
UDP 500/4500 用于握手与 NAT-T；访问宿主机或转发业务流量的放行同时匹配 VPN 地址池和 IPsec 策略，避免仅凭源地址放行。
正常停止会清理自有规则，下次启动会回收异常退出留下的自有规则，再按新模式和地址池重新建立。
同名链被其他服务占用或被外部规则引用时会报错，不清空外部链。历史版本留下的无标记规则不会自动删除；升级时需自行确认旧规则，尤其是旧地址池的 MASQUERADE，不要清空整个宿主机防火墙。

启动前校验配置、账号、证书身份/有效期与密钥匹配；VICI 就绪且连接、凭据加载成功后才标记服务就绪。
健康检查检测就绪标记和 VICI 响应，不检测真实客户端或互联网连通性；`unhealthy` 状态本身不会触发 Docker 自动重启，进程退出由重启策略处理。
停止宽限期为 30 秒，供 strongSwan 关闭和规则清理。IPv4 转发及网关网卡的 ICMP redirect 设置属于宿主机全局状态，停止后保留，不擅自恢复其他服务可能正在使用的值。
同一宿主机仅运行一个项目实例，不与其他 VPN 实例共享账号目录、专属链和路由表。

依据：[strongSwan NTLM 凭据](https://docs.strongswan.org/docs/5.9/swanctl/swanctlConf.html#_secrets_ntlmsuffix)、[转发与分流](https://docs.strongswan.org/docs/5.9/howtos/forwarding.html)、[farp](https://docs.strongswan.org/docs/5.9/plugins/farp.html)。
