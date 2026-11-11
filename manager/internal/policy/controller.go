package policy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"ikev2/manager/internal/store"
	"ikev2/manager/internal/vpn"
)

const socket = "/run/ikev2-policy.sock"

type Controller struct {
	vpn.Gateway
	pool     string
	mu       sync.Mutex
	accounts map[string]store.Account
	pending  map[string]reservation
	active   map[netip.Addr]link
}

type reservation struct {
	name    string
	expires time.Time
}

type link struct {
	name  string
	ikeID string
	reqID string
}

type request struct {
	Action  string
	Name    string
	IKE     string
	Req     string
	Address string
}

func Start(ctx context.Context, gateway vpn.Gateway, pool string, accounts []store.Account) (*Controller, error) {
	pool, err := normalizePool(pool)
	if err != nil {
		return nil, err
	}
	p := &Controller{
		Gateway: gateway, pool: pool, accounts: make(map[string]store.Account),
		pending: make(map[string]reservation), active: make(map[netip.Addr]link),
	}
	for _, account := range accounts {
		p.accounts[strings.ToLower(account.Name)] = account
	}
	if err := p.program(ctx); err != nil {
		return nil, err
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socket, 0600); err != nil {
		listener.Close()
		return nil, err
	}
	go p.listen(listener)
	return p, nil
}

func (p *Controller) Apply(ctx context.Context, account store.Account) error {
	name := strings.ToLower(account.Name)
	p.mu.Lock()
	previous := p.accounts[name]
	p.accounts[name] = account
	if previous.UploadMbps != account.UploadMbps || previous.DownloadMbps != account.DownloadMbps {
		if err := p.program(ctx); err != nil {
			p.accounts[name] = previous
			p.mu.Unlock()
			return err
		}
	}
	p.mu.Unlock()
	return p.Gateway.Apply(ctx, account)
}

func (p *Controller) listen(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			var req request
			if err := json.NewDecoder(conn).Decode(&req); err != nil {
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			message := ""
			if err := p.handle(ctx, req); err != nil {
				message = err.Error()
			}
			json.NewEncoder(conn).Encode(message)
		}()
	}
}

func (p *Controller) handle(ctx context.Context, req request) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	name := strings.ToLower(req.Name)
	if req.Action == "admit" {
		now := time.Now()
		if err := p.checkLimit(name, req.IKE, now); err != nil {
			return err
		}
		// Unfinished negotiations expire after charon's 30-second half-open timeout.
		p.pending[req.IKE] = reservation{name, now.Add(30 * time.Second)}
		return nil
	}

	address, err := netip.ParseAddr(req.Address)
	if err != nil || !address.Is4() {
		return errors.New("VPN 会话未获得 IPv4 地址")
	}
	current, exists := p.active[address]
	switch req.Action {
	case "up":
		if exists {
			if current.name == name && current.reqID == req.Req {
				return nil
			}
			return errors.New("VPN 地址已被另一条会话占用")
		}
		if !p.accounts[name].Enabled {
			return errors.New("账号不可用")
		}
		now := time.Now()
		hold, reserved := p.pending[req.IKE]
		if !reserved || hold.name != name || !now.Before(hold.expires) {
			if err := p.checkLimit(name, req.IKE, now); err != nil {
				return err
			}
		}
		p.active[address] = link{name, req.IKE, req.Req}
		if err := p.program(ctx); err != nil {
			delete(p.active, address)
			return err
		}
		delete(p.pending, req.IKE)
	case "down":
		// CHILD rekeys retain the request ID even if the IKE ID changed.
		if !exists || current.reqID != req.Req || current.name != name {
			return nil
		}
		delete(p.active, address)
		if err := p.program(ctx); err != nil {
			// A stale IP mapping can transfer a limit to another account.
			log.Fatalf("清理 VPN 地址 %s 的限速规则失败: %v", address, err)
		}
	default:
		return errors.New("无效的 VPN 生命周期操作")
	}
	return nil
}

func (p *Controller) checkLimit(name, ikeID string, now time.Time) error {
	account := p.accounts[name]
	if !account.Enabled {
		return errors.New("账号不可用")
	}
	count := 0
	for id, item := range p.pending {
		if !now.Before(item.expires) {
			delete(p.pending, id)
		} else if item.name == name && id != ikeID {
			count++
		}
	}
	for _, item := range p.active {
		if item.name == name && item.ikeID != ikeID {
			count++
		}
	}
	if account.MaxSessions > 0 && count >= account.MaxSessions {
		return errors.New("该账号已达到并发登录上限")
	}
	return nil
}

func Hook(action string) error {
	var req request
	switch action {
	case "admit":
		req = request{Action: action, Name: os.Getenv("IKE_REMOTE_EAP_ID"), IKE: os.Getenv("IKE_UNIQUE_ID")}
	case "child":
		verb, _, _ := strings.Cut(os.Getenv("PLUTO_VERB"), "-")
		req = request{Action: verb, Name: os.Getenv("PLUTO_XAUTH_ID"), IKE: os.Getenv("PLUTO_UNIQUEID"),
			Req: os.Getenv("PLUTO_REQID"), Address: os.Getenv("PLUTO_PEER_SOURCEIP4_1")}
	default:
		return errors.New("未知的 VPN 钩子")
	}
	if req.Name == "" {
		return errors.New("缺少 EAP 账号")
	}
	if _, err := strconv.ParseUint(req.IKE, 10, 32); err != nil {
		return errors.New("无效的 IKE 会话 ID")
	}
	if action == "child" {
		if _, err := strconv.ParseUint(req.Req, 10, 32); err != nil {
			return errors.New("无效的 IPsec 请求 ID")
		}
	}
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return err
	}
	var message string
	if err := json.NewDecoder(conn).Decode(&message); err != nil {
		return err
	}
	if message != "" {
		return fmt.Errorf("%s", message)
	}
	return nil
}
