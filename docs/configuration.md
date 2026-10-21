# 配置说明

配置入口为部署目录的 `.env`。所有日常选项都有中文注释，模板见 `../.env.example`。
证书仍放在 `ssl/`，新部署不需要单独维护账号文件。

## 配置规则

- 使用 `KEY=VALUE`；空行和 `#` 开头的注释会忽略。一个配置项只能出现一次。
- 支持 UTF-8（含 BOM）和 Windows CRLF 换行；不支持多行值。
- 单引号或双引号内保留空格、冒号、`#`、美元符号和反引号。
- 引号内 `\\` 解析为一个反斜杠，`\"` / `\'` 解析为对应的外层引号；其他反斜杠序列保留字面值。
- 不执行 Shell 命令，不展开 `${变量}`。这与 Compose 自身的 `.env` 插值机制不同。
- 用户名和密码不得为空或含换行。错误消息不打印密码或整行配置。
- 不认识的 `VPN_*`、`NAT_*`、`PROXYARP_*`、`USER_*` 配置会报错，避免拼写错误被静默忽略。
- 其他变量如 `COMPOSE_PROJECT_NAME` 可以保留，供 Compose 使用，但不会导入 VPN 进程。
- `.env` 是运行配置的唯一依据，删除或注释配置后会恢复默认，不保留容器创建时的旧值。

## 参数

| 参数 | 作用 | 未填写/留空时 |
|---|---|---|
| `VPN_DOMAIN` | 连接域名及服务器身份 | 必填，无默认值 |
| `VPN_MODE` | `nat` / `proxyarp` | `nat` |
| `VPN_CERT_FILE` | `ssl/` 内的 fullchain 文件名 | `server.crt` |
| `VPN_KEY_FILE` | `ssl/` 内的私钥文件名 | `server.key` |
| `VPN_DNS` | 逗号分隔的 IPv4 DNS 地址 | NAT：`1.1.1.1,8.8.8.8`；Proxy ARP：池所在 /24 的 `.1` 和 `1.1.1.1` |
| `VPN_ROUTES` | 逗号分隔的 IPv4 目标 CIDR | NAT：`0.0.0.0/0`；Proxy ARP：LAN 网段 |
| `NAT_POOL` | NAT 模式客户端地址池 | `10.66.0.0/24` |
| `PROXYARP_POOL` | 同 LAN 的客户端地址池 | 为兼容旧版仍为 `192.168.0.240/28`；新模板显式使用不含 LAN 广播地址的范围 |
| `PROXYARP_LAN` | 家里 LAN 网段 | 根据地址池推导 `/24` |
| `PROXYARP_GATEWAY` | VPN 非 LAN 流量的下一跳 | 不建立自定义策略路由，使用宿主机原有路由 |
| `USER_编号_NAME` | 用户名，编号为 1..999 | 见账号规则 |
| `USER_编号_PASSWORD` | 同编号用户的密码 | 必须与 NAME 成对填写 |

DNS 和路由列表不能含空格或空列表项，目前只支持 IPv4。
网关不会自动改变 DNS，也不会自动启用全隧道。实际 LAN 不是 /24 或 DNS 不在 `.1` 时应手动填写。

## 账号规则

编号允许不连续，按数字排序；用户名不能重复。每个编号必须有完整且非空的 NAME 和 PASSWORD。
只要存在任何一项有效编号的 `USER_*`，就只使用 `.env` 账号，不合并旧文件；成对配置不完整时会报错，不回退到旧文件。
没有任何 `USER_*` 时，为兼容旧部署仍读取 `config/users.txt`，也兼容旧 `VPN_USERS_FILE` 路径选项。

删除一名用户时同时注释或删除两行。如果已经完成迁移，应清空旧文件内有效账号；这样删除全部 USER_* 后会报“没有有效账号”，而不会恢复旧账号。
`.env` 及备份包含明文密码，应设为 `600`，不要提交 Git。旧 `users.txt` 是历史已跟踪文件，避免将真实密码提交到仓库。

## 旧参数兼容

新非空配置优先；未填写新配置时，使用对应模式的旧参数，最后才使用默认值。
同一组新旧参数同时存在时建议迁移，避免以后编辑了优先级较低的旧参数却看不到效果。

| 新配置 | 兼容的旧配置 |
|---|---|
| `NAT_POOL` | `NAT_VPN_POOL` |
| `PROXYARP_POOL` | `PROXYARP_VPN_POOL` |
| `PROXYARP_LAN` | `PROXYARP_LAN_SUBNET`，其次 `LAN_SUBNET` |
| `VPN_DNS` | 当前模式的 `NAT_DNS1/2` 或 `PROXYARP_DNS1/2` |
| `VPN_ROUTES` | 当前模式的 `NAT_LOCAL_TS` 或 `PROXYARP_LOCAL_TS` |

`VPN_DOMAIN`、`VPN_MODE`、证书参数和 `PROXYARP_GATEWAY` 名称不变。

迁移命令：

```bash
bash scripts/migrate-config.sh
```

迁移在部署机执行，使用现有配置和旧账号生成注释完整的新 `.env`，保留非 VPN 的 Compose 变量。
脚本先校验新文件，再备份旧配置、设置 `600` 权限并替换；不会修改或删除旧账号文件。
当前模式生效的 DNS 和路由会保存为公共配置；之后切换模式仍沿用这组公共值。
备份保存原配置，可用于人工回退；不要用 `.env.example` 直接覆盖现有配置。

## Proxy ARP 与旁路由

地址池必须完全属于家里 LAN，避开 DHCP、现有设备、宿主机和 LAN 网络地址/广播地址。
`192.168.0.0/24` LAN 可用 `192.168.0.201-192.168.0.210` 或 `192.168.0.240/29`，不要包含 `.255`。

指定网关时，网关必须是同 LAN 直接可达的独立设备，且不在池内。旁路由要支持转发、上网 NAT 和回程。
模块按客户端地址池精确匹配源地址，使用表 `20162`、协议标记 `186`、优先级 `219`，先于 strongSwan 默认 `220` 规则；本机交付仍优先。
检测到外部资源占用时会拒绝启动，不修改宿主机默认路由或 strongSwan 的 `220` 表。
正常退出及下一次启动时清理本模块规则；强制终止后的残留会在下次启动清理。
网关功能会关闭宿主机 `all` 及网关网卡的 `send_redirects`，停止后保留此设置。
`farp` 代答在线客户端的 ARP，确保 LAN 回包交给 VPN 服务器。

```bash
ip -4 rule show
ip -4 route show table 20162
ip -4 route show table 220
```

自定义宿主机策略路由时，还需检查更高优先级规则。远程客户端所在网段与家里重叠仍可能产生路由冲突。
同网段虚拟地址不等同于二层桥接，不能保证广播、组播或设备自动发现可用。

依据：[strongSwan 转发与分流](https://docs.strongswan.org/docs/5.9/howtos/forwarding.html)、[farp](https://docs.strongswan.org/docs/5.9/plugins/farp.html)、[配置语法](https://docs.strongswan.org/docs/5.9/config/strongswanConf.html)。
