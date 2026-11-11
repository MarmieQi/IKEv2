package policy

import (
	"context"
	"fmt"
	"net/netip"
	"os/exec"
	"slices"
	"strings"
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

func (p *Controller) program(ctx context.Context) error {
	command := exec.CommandContext(ctx, "nft", "-f", "-")
	command.Stdin = strings.NewReader(p.rules())
	if out, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("应用账号限速规则: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (p *Controller) rules() string {
	var b strings.Builder
	fmt.Fprintf(&b, "add table ip %s\ndelete table ip %s\ntable ip %s {\n", table, table, table)
	addresses := make([]netip.Addr, 0, len(p.active))
	for address := range p.active {
		addresses = append(addresses, address)
	}
	slices.SortFunc(addresses, netip.Addr.Compare)
	for _, direction := range []string{"upload", "download"} {
		chains := make(map[string]string)
		var elements []string
		for _, address := range addresses {
			name := p.active[address].name
			account := p.accounts[name]
			rate := account.UploadMbps
			if direction == "download" {
				rate = account.DownloadMbps
			}
			verdict := "return"
			if rate != 0 {
				chain, exists := chains[name]
				if !exists {
					chain = fmt.Sprintf("%s_%d", direction, len(chains))
					chains[name] = chain
					fmt.Fprintf(&b, " chain %s { limit rate over %d bytes/second counter drop; }\n", chain, rate*125000)
				}
				verdict = "goto " + chain
			}
			elements = append(elements, address.String()+" : "+verdict)
		}
		fmt.Fprintf(&b, " map %s { type ipv4_addr : verdict;", direction)
		if len(elements) > 0 {
			fmt.Fprintf(&b, " elements = { %s };", strings.Join(elements, ", "))
		}
		b.WriteString(" }\n")
	}
	fmt.Fprintf(&b, " chain from_vpn { ip saddr vmap @upload; ip saddr %s drop; }\n", p.pool)
	fmt.Fprintf(&b, " chain to_vpn { ip daddr vmap @download; ip daddr %s drop; }\n", p.pool)
	b.WriteString(" chain input { type filter hook input priority -1; policy accept; meta ipsec exists jump from_vpn; }\n")
	b.WriteString(" chain output { type filter hook output priority -1; policy accept; rt ipsec exists jump to_vpn; }\n")
	b.WriteString(" chain forward { type filter hook forward priority -1; policy accept; meta ipsec exists jump from_vpn; rt ipsec exists jump to_vpn; }\n")
	b.WriteString("}\n")
	return b.String()
}
