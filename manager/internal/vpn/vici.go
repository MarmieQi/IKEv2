package vpn

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"

	"github.com/strongswan/govici/vici"
	"ikev2/manager/internal/store"
)

type Session struct {
	ID      string
	Account string
	Address string
	Peer    string
	Traffic map[string]Traffic
}

type Traffic struct {
	Upload   uint64 `json:"upload"`
	Download uint64 `json:"download"`
}

type Gateway interface {
	Apply(context.Context, store.Account) error
	Sessions(context.Context) ([]Session, error)
}

type VICI struct{ Socket string }

func (v VICI) connect(ctx context.Context) (*vici.Session, error) {
	dialer := net.Dialer{}
	return vici.NewSession(vici.WithSocketPath(v.Socket), vici.WithDialContext(func(_ context.Context, network, address string) (net.Conn, error) {
		return dialer.DialContext(ctx, network, address)
	}))
}

func call(ctx context.Context, session *vici.Session, command string, params map[string]any) error {
	request := vici.NewMessage()
	for key, value := range params {
		if err := request.Set(key, value); err != nil {
			return err
		}
	}
	reply, err := session.Call(ctx, command, request)
	if err != nil {
		return err
	}
	return reply.Err()
}

func (v VICI) Apply(ctx context.Context, account store.Account) error {
	session, err := v.connect(ctx)
	if err != nil {
		return err
	}
	defer session.Close()
	id := "manager-" + account.Name
	if account.Enabled {
		return call(ctx, session, "load-shared", map[string]any{
			"id": id, "type": "NTLM", "data": string(account.Hash), "owners": []string{account.Name},
		})
	}
	// strongSwan's unload-shared is idempotent for a missing key.
	if err := call(ctx, session, "unload-shared", map[string]any{"id": id}); err != nil {
		return err
	}
	items, err := list(ctx, session)
	if err != nil {
		return err
	}
	for _, item := range items {
		if strings.EqualFold(item.Account, account.Name) {
			if err := terminate(ctx, session, item.ID); err != nil {
				return err
			}
		}
	}
	return nil
}

func (v VICI) Sessions(ctx context.Context) ([]Session, error) {
	session, err := v.connect(ctx)
	if err != nil {
		return nil, err
	}
	defer session.Close()
	return list(ctx, session)
}

func list(ctx context.Context, session *vici.Session) ([]Session, error) {
	var items []Session
	for message, err := range session.CallStreaming(ctx, "list-sas", "list-sa", nil) {
		if err != nil {
			return nil, err
		}
		sa, ok := message.Get("ikev2-mschapv2").(*vici.Message)
		if !ok || (sa.Get("state") != "ESTABLISHED" && sa.Get("state") != "REKEYING") {
			continue
		}
		id, _ := sa.Get("uniqueid").(string)
		account, _ := sa.Get("remote-eap-id").(string)
		// VICI omits remote-eap-id when it equals remote-id.
		if account == "" {
			account, _ = sa.Get("remote-id").(string)
		}
		addresses, _ := sa.Get("remote-vips").([]string)
		peer, _ := sa.Get("remote-host").(string)
		if id == "" || account == "" {
			return nil, errors.New("VPN 会话缺少标识或 EAP 账号")
		}
		items = append(items, Session{ID: id, Account: account, Address: strings.Join(addresses, ", "), Peer: peer, Traffic: childTraffic(sa)})
	}
	return items, nil
}

func childTraffic(sa *vici.Message) map[string]Traffic {
	counters := make(map[string]Traffic)
	children, ok := sa.Get("child-sas").(*vici.Message)
	if !ok {
		return counters
	}
	for _, key := range children.Keys() {
		child, ok := children.Get(key).(*vici.Message)
		if !ok {
			continue
		}
		id, _ := child.Get("uniqueid").(string)
		in, _ := child.Get("bytes-in").(string)
		out, _ := child.Get("bytes-out").(string)
		upload, inErr := strconv.ParseUint(in, 10, 64)
		download, outErr := strconv.ParseUint(out, 10, 64)
		if id != "" && inErr == nil && outErr == nil {
			counters[id] = Traffic{Upload: upload, Download: download}
		}
	}
	return counters
}

func terminate(ctx context.Context, session *vici.Session, id string) error {
	if err := call(ctx, session, "terminate", map[string]any{"ike-id": id, "timeout": "2000", "force": "yes"}); err != nil {
		return fmt.Errorf("断开会话 %s: %w", id, err)
	}
	return nil
}
