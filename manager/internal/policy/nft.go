package policy

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/netip"
	"os/exec"
	"strings"

	"ikev2/manager/internal/store"
)

const table = "ikev2_account_policy"

func normalizePool(value string) (string, error) {
	if prefix, err := netip.ParsePrefix(value); err == nil && prefix.Addr().Is4() {
		return prefix.Masked().String(), nil
	}
	first, last, ok := strings.Cut(value, "-")
	if ok {
		a, errA := netip.ParseAddr(first)
		b, errB := netip.ParseAddr(last)
		if errA == nil && errB == nil && a.Is4() && b.Is4() && a.Compare(b) <= 0 {
			return a.String() + "-" + b.String(), nil
		}
	}
	return "", fmt.Errorf("无效的 VPN IPv4 地址池")
}

func program(ctx context.Context, rules string) error {
	command := exec.CommandContext(ctx, "nft", "-f", "-")
	command.Stdin = strings.NewReader(rules)
	if out, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("应用账号限速规则: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (p *Controller) baseRules() string {
	var b strings.Builder
	fmt.Fprintf(&b, "add table ip %s\ndelete table ip %s\ntable ip %s {\n", table, table, table)
	b.WriteString(" map upload { type ipv4_addr : verdict; }\n map download { type ipv4_addr : verdict; }\n")
	fmt.Fprintf(&b, " chain from_vpn { ip saddr vmap @upload; ip saddr %s drop; }\n", p.pool)
	fmt.Fprintf(&b, " chain to_vpn { ip daddr vmap @download; ip daddr %s drop; }\n", p.pool)
	b.WriteString(" chain input { type filter hook input priority -1; policy accept; meta ipsec exists jump from_vpn; }\n")
	b.WriteString(" chain output { type filter hook output priority -1; policy accept; rt ipsec exists jump to_vpn; }\n")
	b.WriteString(" chain forward { type filter hook forward priority -1; policy accept; meta ipsec exists jump from_vpn; rt ipsec exists jump to_vpn; }\n")
	b.WriteString("}\n")
	return b.String()
}

func accountChains(name string) [2]string {
	id := sha256.Sum256([]byte(name))
	return [2]string{fmt.Sprintf("up_%x", id), fmt.Sprintf("down_%x", id)}
}

func writeLimit(b *strings.Builder, chain string, rate int) {
	if rate > 0 {
		fmt.Fprintf(b, "add rule ip %s %s limit rate over %d bytes/second counter drop\n", table, chain, int64(rate)*125000)
	}
}

func sessionRules(name string, address netip.Addr, limits store.Limits, add, changeChains bool) string {
	var b strings.Builder
	chains := accountChains(name)
	rates := [2]int{limits.UploadMbps, limits.DownloadMbps}
	for i, direction := range [2]string{"upload", "download"} {
		chain := chains[i]
		if add {
			if changeChains {
				fmt.Fprintf(&b, "add chain ip %s %s\n", table, chain)
				writeLimit(&b, chain, rates[i])
			}
			fmt.Fprintf(&b, "add element ip %s %s { %s : goto %s }\n", table, direction, address, chain)
		} else {
			fmt.Fprintf(&b, "delete element ip %s %s { %s }\n", table, direction, address)
			if changeChains {
				fmt.Fprintf(&b, "flush chain ip %s %s\n", table, chain)
				fmt.Fprintf(&b, "delete chain ip %s %s\n", table, chain)
			}
		}
	}
	return b.String()
}

func rateRules(name string, previous, next store.Limits) string {
	oldRates := [2]int{previous.UploadMbps, previous.DownloadMbps}
	newRates := [2]int{next.UploadMbps, next.DownloadMbps}
	if oldRates == newRates {
		return ""
	}
	var b strings.Builder
	for i, chain := range accountChains(name) {
		if oldRates[i] != newRates[i] {
			fmt.Fprintf(&b, "flush chain ip %s %s\n", table, chain)
			writeLimit(&b, chain, newRates[i])
		}
	}
	return b.String()
}
