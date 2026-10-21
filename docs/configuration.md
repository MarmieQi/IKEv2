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
alice:plain:你的密码
bob:plain:可包含冒号:以及 # 空格和引号
```

- 用户名仅限英文字母、数字、下划线、点、@ 和连字符，不得重复。
- 第二个冒号后的全部内容都是密码，不做变量替换、去空格或引号解析；不要额外包引号。
- 密码不能为空或含回车/换行。文件支持 UTF-8 和 CRLF。
- 空行和 # 开头的注释忽略；通过注释整行禁用账号。
- 只能显式使用 `plain` 或 `nt` 类型；`用户名:密码` 旧格式会报错。

容器启动时把 plain 密码转换成 NT 哈希，原子替换文件内容：

```text
alice:nt:32位十六进制NT哈希
```

已有 nt 行不会重复计算。密码重置时将该行改回 `alice:plain:新密码`，然后重启容器。
客户端始终输入原始密码。删除或禁用账号后需要重启，现有 VPN 连接会随重启断开。

EAP-MSCHAPv2 需要 NT 哈希 `MD4(UTF-16LE(password))`，因此不能直接改用 bcrypt/Argon2 等哈希。
strongSwan 使用 `ntlm` 类型凭据及 `secret = 0x...` 加载 NT 哈希，运行配置不保存明文密码。
这不是可逆加密，哈希本身仍是敏感凭据，账号文件、锁及临时文件权限均为 600。

启动使用同目录锁文件（最长等待 10 秒），完成全文件校验后才写回；转换失败或检测到编辑变动时不覆盖原文件。
写回采用同目录临时文件和原子重命名，不生成明文备份；config/ 必须可写且使用目录挂载。
不要同时启动多个服务实例共享同一份账号文件。编辑器若恰好在最终检查与替换之间保存，仍可能产生竞争，应在修改完成后再重启。
实际 users.txt、锁、临时文件和账号备份由 Git 及 Docker 构建上下文忽略。

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

依据：[strongSwan NTLM 凭据](https://docs.strongswan.org/docs/5.9/swanctl/swanctlConf.html#_secrets_ntlmsuffix)、[转发与分流](https://docs.strongswan.org/docs/5.9/howtos/forwarding.html)、[farp](https://docs.strongswan.org/docs/5.9/plugins/farp.html)。
