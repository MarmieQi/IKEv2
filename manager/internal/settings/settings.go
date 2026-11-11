package settings

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/netip"
	"os/exec"
	"regexp"
	"strings"

	"ikev2/manager/internal/store"
)

var Keys = [...]string{
	"VPN_DOMAIN", "VPN_MODE", "VPN_CERT_FILE", "VPN_KEY_FILE",
	"VPN_DNS", "VPN_ROUTES", "NAT_POOL", "PROXYARP_POOL", "PROXYARP_LAN", "PROXYARP_GATEWAY",
}

var domain = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$`)

func Parse(input store.VPNSettings) (store.VPNSettings, error) {
	values := make(store.VPNSettings, len(Keys))
	for _, key := range Keys {
		value := strings.TrimSpace(input[key])
		values[key] = value
		if strings.ContainsAny(value, "\r\n\x00") {
			return values, fmt.Errorf("%s 不能包含换行。", key)
		}
	}
	host := values["VPN_DOMAIN"]
	if !domain.MatchString(host) || strings.Contains(host, "..") {
		return values, errors.New("请填写有效的连接域名或 IPv4 地址。")
	}
	if values["VPN_MODE"] == "" {
		values["VPN_MODE"] = "nat"
	}
	if values["VPN_MODE"] != "nat" && values["VPN_MODE"] != "proxyarp" {
		return values, errors.New("请选择 NAT 或 Proxy ARP 模式。")
	}
	for _, key := range []string{"VPN_CERT_FILE", "VPN_KEY_FILE"} {
		value := values[key]
		if value == "." || value == ".." || strings.ContainsAny(value, "/\\") {
			return values, errors.New("证书和私钥只能填写 ssl/ 目录中的文件名。")
		}
	}
	for _, key := range []string{"VPN_DNS", "VPN_ROUTES"} {
		if values[key] == "" {
			continue
		}
		items := strings.Split(values[key], ",")
		for i, item := range items {
			item = strings.TrimSpace(item)
			if key == "VPN_DNS" {
				if !ipv4(item).IsValid() {
					return values, fmt.Errorf("DNS 第 %d 项必须是 IPv4 地址。", i+1)
				}
			} else if !cidr(item).IsValid() {
				return values, fmt.Errorf("VPN 路由范围第 %d 项必须是对齐的 IPv4 CIDR。", i+1)
			}
			items[i] = item
		}
		values[key] = strings.Join(items, ",")
	}
	for _, key := range []string{"NAT_POOL", "PROXYARP_POOL"} {
		if values[key] != "" && !validPool(values[key]) {
			return values, fmt.Errorf("%s 必须是对齐的 IPv4 CIDR 或起始 IP-结束 IP。", key)
		}
	}
	if value := values["PROXYARP_LAN"]; value != "" && !cidr(value).IsValid() {
		return values, errors.New("局域网网段必须是对齐的 IPv4 CIDR。")
	}
	if value := values["PROXYARP_GATEWAY"]; value != "" && !ipv4(value).IsValid() {
		return values, errors.New("网关必须是 IPv4 地址。")
	}
	return values, nil
}

func ipv4(value string) netip.Addr {
	address, _ := netip.ParseAddr(value)
	if !address.Is4() {
		return netip.Addr{}
	}
	return address
}

func cidr(value string) netip.Prefix {
	prefix, _ := netip.ParsePrefix(value)
	if !prefix.Addr().Is4() || prefix != prefix.Masked() {
		return netip.Prefix{}
	}
	return prefix
}

func validPool(value string) bool {
	if cidr(value).IsValid() {
		return true
	}
	first, last, ok := strings.Cut(value, "-")
	start, end := ipv4(first), ipv4(last)
	return ok && start.IsValid() && end.IsValid() && start.Compare(end) <= 0
}

func Decode(lines []string) store.VPNSettings {
	values := make(store.VPNSettings, len(Keys))
	for _, line := range lines {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = value
		}
	}
	return values
}

func Encode(values store.VPNSettings) []string {
	lines := make([]string, 0, len(Keys))
	for _, key := range Keys {
		lines = append(lines, key+"="+values[key])
	}
	return lines
}

func LoadOrSeed(ctx context.Context, db *store.Store, loadInitial func() (store.VPNSettings, error)) (store.VPNSettings, error) {
	saved, err := db.VPNSettings(ctx)
	if err == nil && len(saved) != len(Keys) {
		return nil, errors.New("数据库中的 VPN 设置不完整")
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return saved, err
	}
	initial, err := loadInitial()
	if err != nil {
		return nil, err
	}
	values, err := Parse(initial)
	if err != nil {
		return nil, err
	}
	if err := db.SeedVPNSettings(ctx, values); err != nil {
		return nil, err
	}
	return db.VPNSettings(ctx)
}

func ReadEnv(ctx context.Context, path string) (store.VPNSettings, error) {
	const script = `
set -euo pipefail
source /usr/local/lib/ikev2/runtime-config.sh
declare -A raw=()
runtime_config_load "$1" raw >&2
for key in "${!raw[@]}"; do
    printf '%s=%s\n' "$key" "${raw[$key]}"
done
`
	output, err := exec.CommandContext(ctx, "bash", "-c", script, "vpn-settings", path).Output()
	if err != nil {
		var processError *exec.ExitError
		if errors.As(err, &processError) && len(processError.Stderr) != 0 {
			return nil, errors.New(strings.TrimSpace(string(processError.Stderr)))
		}
		return nil, err
	}
	return Decode(strings.Split(string(output), "\n")), nil
}

func ValidateHost(ctx context.Context, values store.VPNSettings) error {
	const script = `
set -euo pipefail
source /usr/local/lib/ikev2/runtime-config.sh
source /usr/local/lib/ikev2/network-config.sh
source /usr/local/lib/ikev2/certificates.sh
declare -A raw=() config=()
for setting in "$@"; do
    key="${setting%%=*}"
    runtime_config_key_known "$key" || exit 1
    raw["$key"]="${setting#*=}"
done
network_config_resolve raw config
network_host_validate config
certificates_validate "/ssl/${config[cert_file]}" "/ssl/${config[key_file]}" "${config[domain]}"
`
	args := append([]string{"-c", script, "vpn-settings"}, Encode(values)...)
	output, err := exec.CommandContext(ctx, "bash", args...).CombinedOutput()
	if err != nil {
		if message := strings.TrimSpace(string(output)); message != "" {
			return errors.New(message)
		}
		return fmt.Errorf("无法校验 NAS 网络和证书配置: %w", err)
	}
	return nil
}
