package policy

import (
	"context"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"ikev2/manager/internal/store"
)

func TestConcurrentAdmission(t *testing.T) {
	p := &Controller{
		accounts: map[string]store.Account{"alice": {Enabled: true, Limits: store.Limits{MaxSessions: 1}}},
		pending:  make(map[string]reservation),
	}
	var admitted atomic.Int32
	var attempts sync.WaitGroup
	for _, id := range []string{"1", "2"} {
		attempts.Go(func() {
			if p.handle(t.Context(), request{Action: "admit", Name: "alice", IKE: id}) == nil {
				admitted.Add(1)
			}
		})
	}
	attempts.Wait()
	if got := admitted.Load(); got != 1 {
		t.Fatalf("admitted %d simultaneous connections, want 1", got)
	}
}

func TestSharedRateRules(t *testing.T) {
	p := &Controller{
		pool: "192.168.0.201-192.168.0.250",
		accounts: map[string]store.Account{
			"alice": {Limits: store.Limits{UploadMbps: 5, DownloadMbps: 20}},
			"bob":   {},
		},
		active: map[netip.Addr]link{
			netip.MustParseAddr("192.168.0.201"): {name: "alice"},
			netip.MustParseAddr("192.168.0.202"): {name: "alice"},
			netip.MustParseAddr("192.168.0.203"): {name: "bob"},
		},
	}
	rules := p.rules()
	for _, expected := range []string{
		"192.168.0.201 : goto upload_0, 192.168.0.202 : goto upload_0, 192.168.0.203 : return",
		"192.168.0.201 : goto download_0, 192.168.0.202 : goto download_0, 192.168.0.203 : return",
		"limit rate over 625000 bytes/second",
		"limit rate over 2500000 bytes/second",
	} {
		if !strings.Contains(rules, expected) {
			t.Errorf("missing %q", expected)
		}
	}
	// This opt-in check must be run in a disposable network namespace.
	if os.Getenv("IKEV2_TEST_NFT_NAMESPACE") == "yes" {
		for range 2 {
			if err := p.program(context.Background()); err != nil {
				t.Fatal(err)
			}
		}
	}
}
