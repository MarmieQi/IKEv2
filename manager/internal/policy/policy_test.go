package policy

import (
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
	p := &Controller{pool: "192.168.0.201-192.168.0.250"}
	first := netip.MustParseAddr("192.168.0.201")
	second := netip.MustParseAddr("192.168.0.202")
	other := netip.MustParseAddr("192.168.0.203")
	limits := store.Limits{UploadMbps: 5, DownloadMbps: 20}
	chains := accountChains("alice")
	initial := sessionRules("alice", first, limits, true, true)
	next := sessionRules("alice", second, limits, true, false)
	for _, expected := range []string{
		"limit rate over 625000 bytes/second",
		"limit rate over 2500000 bytes/second",
	} {
		if !strings.Contains(initial, expected) {
			t.Errorf("missing %q", expected)
		}
	}
	for _, chain := range chains {
		if !strings.Contains(initial, "goto "+chain) || !strings.Contains(next, "goto "+chain) {
			t.Fatalf("sessions do not share chain %s", chain)
		}
	}
	changed := rateRules("alice", limits, store.Limits{DownloadMbps: 20})
	if !strings.Contains(changed, "flush chain ip "+table+" "+chains[0]) || strings.Contains(changed, chains[1]) {
		t.Fatal("upload rate change must only replace the upload rule")
	}
	if strings.Count(next, "\n") != 2 || strings.Contains(next, "chain ") {
		t.Fatal("adding a second session must only add its two map entries")
	}
	// This opt-in check must be run in a disposable network namespace.
	if os.Getenv("IKEV2_TEST_NFT_NAMESPACE") == "yes" {
		for _, rules := range []string{
			p.baseRules(), initial, next, sessionRules("bob", other, store.Limits{}, true, true), changed,
			sessionRules("alice", first, store.Limits{}, false, false),
			sessionRules("alice", second, store.Limits{}, false, true),
			sessionRules("bob", other, store.Limits{}, false, true),
			p.baseRules(),
		} {
			if err := program(t.Context(), rules); err != nil {
				t.Fatalf("%v\n%s", err, rules)
			}
		}
	}
}
