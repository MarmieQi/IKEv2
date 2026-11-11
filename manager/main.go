package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
	"ikev2/manager/internal/accounts"
	"ikev2/manager/internal/policy"
	"ikev2/manager/internal/settings"
	"ikev2/manager/internal/store"
	"ikev2/manager/internal/vpn"
	"ikev2/manager/internal/web"
)

const database = "/data/manager.db"

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}

func run(args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	gateway := vpn.VICI{Socket: "/var/run/charon.vici"}
	if len(args) == 1 && args[0] == "init" {
		return initialize(ctx, database, "/etc/ikev2/admin.json")
	}
	if len(args) == 1 && args[0] == "preview" {
		return preview(ctx)
	}
	if len(args) == 2 && args[0] == "hook" {
		return policy.Hook(args[1])
	}
	check := len(args) == 2 && args[0] == "check"
	if !check && !(len(args) == 3 && args[0] == "serve") {
		return errors.New("用法: ikev2-manager init | check <.env 路径> | serve <地址池> <启动配置> | preview")
	}
	db, err := store.Open(database)
	if err != nil {
		return fmt.Errorf("打开账号数据库: %w", err)
	}
	defer db.Close()
	admin, password, err := db.Admin(ctx)
	if err != nil {
		return fmt.Errorf("读取管理员账号: %w", err)
	}
	if check {
		values, err := settings.LoadOrSeed(ctx, db, func() (store.VPNSettings, error) {
			return settings.ReadEnv(ctx, args[1])
		})
		if err != nil {
			return fmt.Errorf("读取 VPN 设置: %w", err)
		}
		fmt.Println(strings.Join(settings.Encode(values), "\n"))
		return nil
	}
	items, err := db.Accounts(ctx)
	if err != nil {
		return err
	}
	controller, err := policy.Start(ctx, gateway, args[1], items)
	if err != nil {
		return err
	}
	service := &accounts.Service{Store: db, VPN: controller}
	if err := service.ApplyAll(ctx, items); err != nil {
		return err
	}
	return serve(&web.Server{
		Accounts: service, Admin: admin, PasswordHash: password,
		ActiveSettings: settings.Decode(strings.Split(args[2], "\n")),
	})
}

func initialize(ctx context.Context, dbPath, configPath string) (err error) {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("读取后台初始化配置: %w", err)
	}
	defer clear(raw)
	var config struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if json.Unmarshal(raw, &config) != nil || !accounts.ValidName(config.Username) ||
		len(config.Password) == 0 || len(config.Password) > 72 {
		return errors.New("admin.json 必须包含有效的 username 和 1 到 72 字节的 password")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(config.Password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if err := store.CreateFile(dbPath); err != nil {
		return fmt.Errorf("创建账号数据库: %w", err)
	}
	defer func() {
		if err != nil {
			os.Remove(dbPath)
		}
	}()
	db, err := store.Open(dbPath)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.Init(ctx, config.Username, hash, nil); err != nil {
		return err
	}
	fmt.Printf("后台管理员 %s 已初始化。请登录后台新建 VPN 账号。\n", config.Username)
	return nil
}

func serve(webServer *web.Server) error {
	address := "0.0.0.0:8787"
	if webServer.Preview {
		address = "127.0.0.1:8787"
	}
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return err
	}
	defer listener.Close()
	server := &http.Server{
		Handler: webServer.Handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second,
		MaxHeaderBytes: 16 << 10,
	}
	if !webServer.Preview {
		if err := os.WriteFile("/run/ikev2.ready", nil, 0644); err != nil {
			return err
		}
		log.Print("IKEv2 已就绪")
	}
	log.Printf("管理页面 http://%s", address)
	return server.Serve(listener)
}

func preview(ctx context.Context) error {
	db, err := store.Open(":memory:")
	if err != nil {
		return err
	}
	defer db.Close()
	items := []store.Account{
		{Name: "home-admin", Hash: make([]byte, 16)}, {Name: "studio", Hash: make([]byte, 16)},
		{Name: "travel", Hash: make([]byte, 16)}, {Name: "guest", Hash: make([]byte, 16)},
	}
	password, err := bcrypt.GenerateFromPassword([]byte("ikev2-preview"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if err := db.Init(ctx, "admin", password, items); err != nil {
		return err
	}
	active, err := settings.Parse(store.VPNSettings{
		"VPN_DOMAIN": "vpn.example.com", "VPN_MODE": "nat",
		"VPN_CERT_FILE": "server.crt", "VPN_KEY_FILE": "server.key",
		"VPN_DNS": "1.1.1.1,8.8.8.8", "VPN_ROUTES": "0.0.0.0/0",
		"NAT_POOL": "10.66.0.0/24", "PROXYARP_POOL": "192.168.0.201-192.168.0.210",
	})
	if err != nil {
		return err
	}
	if err := db.SeedVPNSettings(ctx, active); err != nil {
		return err
	}
	items[3].Enabled = false
	if err := db.Update(ctx, items[3]); err != nil {
		return err
	}
	if err := db.Applied(ctx, items[3].Name); err != nil {
		return err
	}
	gateway := &previewVPN{items: []vpn.Session{
		{ID: "1", Account: "home-admin", Address: "192.168.0.201", Peer: "203.0.113.24"},
		{ID: "2", Account: "studio", Address: "192.168.0.202", Peer: "198.51.100.18"},
	}}
	return serve(&web.Server{
		Accounts: &accounts.Service{Store: db, VPN: gateway},
		Admin:    "admin", PasswordHash: password, Preview: true, ActiveSettings: active,
	})
}

type previewVPN struct {
	mu    sync.Mutex
	items []vpn.Session
	start time.Time
}

func (v *previewVPN) Apply(_ context.Context, account store.Account) error {
	if account.Enabled {
		return nil
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	for i := len(v.items) - 1; i >= 0; i-- {
		if v.items[i].Account == account.Name {
			v.items = append(v.items[:i], v.items[i+1:]...)
		}
	}
	return nil
}

func (v *previewVPN) Sessions(context.Context) ([]vpn.Session, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.start.IsZero() {
		v.start = time.Now()
	}
	elapsed := time.Since(v.start).Seconds()
	items := append([]vpn.Session(nil), v.items...)
	for i := range items {
		items[i].Traffic = map[string]vpn.Traffic{
			"demo": {Upload: uint64(elapsed * 87500), Download: uint64(elapsed * 575000)},
		}
	}
	return items, nil
}

func (v *previewVPN) Disconnect(_ context.Context, id string) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	for i, item := range v.items {
		if item.ID == id {
			v.items = append(v.items[:i], v.items[i+1:]...)
			return nil
		}
	}
	return errors.New("会话已离线")
}
