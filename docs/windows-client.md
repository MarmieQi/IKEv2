# Windows 原生 IKEv2 客户端

本指南适用于 Windows 10/11 内置 VPN 客户端，使用 IKEv2、服务器证书和 EAP-MSCHAPv2 用户名/密码连接本项目。它不适用于 Windows 上部署服务端。

服务端通过证书验证自身，通过 EAP-MSCHAPv2 验证客户端账号；strongSwan 官方要求 EAP 身份交换插件参与该流程。本项目在 [`strongswan.conf`](../config/strongswan.conf) 中显式加载 `eap-identity` 和 `eap-mschapv2`。

strongSwan 官方指出，Windows 默认 IKE 提案只使用 MODP1024；默认 ESP 提案还包括 DES 和 NULL。只创建连接并成功登录，并不能证明使用了强算法。以下先按 strongSwan 官方 GUI 流程配置，再说明如何让 Windows 精确使用本项目首选算法。

## 1. 确认服务器证书受信任

`VPN_DOMAIN` 必须和服务器证书 SAN 中的 DNS 名称一致，且证书链有效。

使用公共 CA 签发的证书时，Windows 必须能验证该 CA 链。使用自建或私有 CA 时，先把 **CA 根证书** 导入 Windows 的“本地计算机 → 受信任的根证书颁发机构”存储区。不要把服务器叶证书误当作 CA 根证书导入。官方导入流程见 [Storing a Windows CA Certificate](https://docs.strongswan.org/docs/latest/interop/windowsCaCert.html)。

## 2. 按官方界面创建 VPN 连接

打开“设置 → 网络和 Internet → VPN → 添加 VPN”，填写：

| 字段 | 值 |
|---|---|
| VPN 提供商 | Windows（内置） |
| 连接名称 | 自选，例如 `IKEv2` |
| 服务器名称或地址 | `.env` 中的 `VPN_DOMAIN` |
| VPN 类型 | IKEv2 |
| 登录信息类型 | 用户名和密码 |

连接时输入 `config/users.txt` 中的用户名和原始密码。文件里的 `{NT}` 哈希不是登录密码；本项目按账号文件中的用户名匹配身份，不要在用户名中添加 `DOMAIN\` 前缀。

## 3. 官方默认策略加固

采用 Windows 默认算法策略时，按 strongSwan 官方指南完成以下两项加固。

先在“控制面板 → 网络连接”中找到该 VPN 的 **EAP WAN Miniport (IKEv2)** 连接，打开“属性 → 安全”，把“数据加密”设为 **Maximum strength encryption（最高强度加密）**。不要选相邻的“Require encryption（需要加密）”选项。此项用于移除默认 ESP 提案中的 DES 和 NULL。

再启用 MODP2048。用管理员权限打开注册表编辑器，定位到：

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Rasman\Parameters
```

新建或修改 `DWORD (32 位)` 值：

```text
名称：NegotiateDH2048_AES256
数值：2
```

数值 `2` 表示强制使用 AES-256 和 MODP2048。注册表路径、取值含义和默认提案背景见 strongSwan 的 [Windows Clients](https://docs.strongswan.org/docs/latest/interop/windowsClients.html)。完成后断开并重新连接 VPN。

## 4. 可选：使用服务器首选算法（替代第 3 步）

若希望 Windows 精确使用本项目当前首选的 AES-128-CBC / SHA-256 / MODP2048 IKE，以及 AES-128-CBC / SHA-256 ESP，可用 Microsoft 官方的 `Set-VpnConnectionIPsecConfiguration` cmdlet 设置连接策略。该方案替代第 3 步的“最高强度加密”和注册表 `NegotiateDH2048_AES256=2` 设置；两种策略目标不同，不能混用。若已设置该 DWORD，将其删除以恢复 Windows 默认值，再应用下面的连接级策略：

```powershell
Set-VpnConnectionIPsecConfiguration `
  -ConnectionName "IKEv2" `
  -AuthenticationTransformConstants SHA256128 `
  -CipherTransformConstants AES128 `
  -DHGroup Group14 `
  -EncryptionMethod AES128 `
  -IntegrityCheckMethod SHA256 `
  -PfsGroup None `
  -Force
```

把 `IKEv2` 改成第 2 步的连接名称。这里 `Group14` 对应 MODP2048，`PfsGroup None` 与服务器当前不为 ESP 配置额外 DH/PFS 组相匹配。此 cmdlet 的正式参数和示例见 [Microsoft Set-VpnConnectionIPsecConfiguration](https://learn.microsoft.com/en-us/powershell/module/vpnclient/set-vpnconnectionipsecconfiguration)。

strongSwan 官方说明 Windows 10 及更新版本可通过该 cmdlet 配置更强的算法。服务器当前对应提案在 [`strongswan.sh`](../scripts/lib/strongswan.sh) 中。若 VPN 是所有用户共享的连接，按 Microsoft 文档加上 `-AllUserConnection`。

## 5. 连接、全隧道和验证

在“设置 → 网络和 Internet → VPN”中选择连接并点击“连接”，按提示输入用户名和密码。strongSwan 官方连接与状态检查步骤见 [Windows Client EAP Connection with Passwords](https://docs.strongswan.org/docs/latest/interop/windowsEapConnect.html)。

本项目 `.env` 的 `VPN_ROUTES` 决定服务端允许进入隧道的目标网段。需要全局 IPv4 流量走 VPN 时，设置 `VPN_ROUTES=0.0.0.0/0`，并在管理员 PowerShell 中关闭该连接的分流：

```powershell
Set-VpnConnection -Name "IKEv2" -SplitTunneling $false
```

strongSwan 说明 Windows 10 新建连接默认启用了分流；只在服务器发送 `0.0.0.0/0` 路由选择器时关闭分流，才能形成全隧道。若连接保存在所有用户的全局电话簿，命令还需加 `-AllUserConnection`，见 [Microsoft Set-VpnConnection](https://learn.microsoft.com/en-us/powershell/module/vpnclient/set-vpnconnection)。

连接成功后，在服务器查看实际协商结果：

```bash
docker exec ikev2-mschapv2 swanctl --list-sas
```

检查 IKE SA 是否使用 MODP2048（或 `MODP_2048`），以及 CHILD_SA 是否使用预期的 AES/SHA 组合。旧算法仍在服务器提案中作为兼容回退；如果结果落到 MODP1024、SHA-1 或 3DES，应检查 Windows 策略是否真正应用，而不要只凭“已连接”判断。

官方资料：

- [Windows Client EAP Configuration with Passwords](https://docs.strongswan.org/docs/latest/interop/windowsEapConf.html)
- [Windows Clients：默认算法、PowerShell 与重协商行为](https://docs.strongswan.org/docs/latest/interop/windowsClients.html)
- [Windows CA 证书导入](https://docs.strongswan.org/docs/latest/interop/windowsCaCert.html)
- [Microsoft：配置 IKEv2 客户端加密策略](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/vpn/how-to-configure-diffie-hellman-protocol-over-ikev2-vpn-connections)
