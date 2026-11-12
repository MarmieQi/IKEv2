package web

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"maps"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"ikev2/manager/internal/accounts"
	"ikev2/manager/internal/settings"
	"ikev2/manager/internal/store"
	"ikev2/manager/internal/vpn"
)

//go:embed templates/*.html static/*
var files embed.FS

var pages = template.Must(template.ParseFS(files, "templates/*.html"))

type Server struct {
	Accounts       *accounts.Service
	Admin          string
	PasswordHash   []byte
	Preview        bool
	ActiveSettings store.VPNSettings
	RequestRestart func()
	sessionMu      sync.Mutex
	sessions       map[string]time.Time
	loginMu        sync.Mutex
	nextLogin      time.Time
}

type row struct {
	store.Account
	Connections int
}

type page struct {
	Admin           string
	Preview         bool
	Tab             string
	Error           string
	Notice          string
	Rows            []row
	Sessions        []vpn.Session
	SessionError    bool
	Enabled         int
	Settings        store.VPNSettings
	SettingsPending bool
	CanRestart      bool
	DNSRows         []string
}

func (s *Server) Handler() http.Handler {
	public := http.NewServeMux()
	admin := http.NewServeMux()
	assets, err := fs.Sub(files, "static")
	if err != nil {
		panic(err)
	}
	public.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(assets))))
	public.HandleFunc("GET /login", s.loginPage)
	public.HandleFunc("POST /login", s.login)
	public.Handle("/", s.auth(admin))
	admin.HandleFunc("POST /logout", s.logout)
	admin.HandleFunc("GET /{$}", s.dashboard)
	admin.HandleFunc("GET /sessions", s.dashboard)
	admin.HandleFunc("GET /sessions/traffic", s.traffic)
	admin.HandleFunc("GET /accounts/connections", s.connections)
	admin.HandleFunc("POST /accounts", s.change)
	admin.HandleFunc("GET /settings", s.vpnSettings)
	admin.HandleFunc("POST /settings", s.saveSettings)
	if s.RequestRestart != nil {
		admin.HandleFunc("POST /settings/restart", s.restart)
	}
	guard := http.NewCrossOriginProtection().Handler(public)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// Keep Origin on same-origin form submissions over LAN HTTP.
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("Cache-Control", "no-store")
		r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
		guard.ServeHTTP(w, r)
	})
}

func (s *Server) vpnSettings(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	values, err := s.Accounts.Store.VPNSettings(ctx)
	if err != nil {
		log.Printf("读取 VPN 设置: %v", err)
		http.Error(w, "读取 VPN 设置失败", http.StatusInternalServerError)
		return
	}
	render(w, "dashboard.html", page{
		Admin: s.Admin, Preview: s.Preview, Tab: "settings",
		Settings: values, SettingsPending: !maps.Equal(values, s.ActiveSettings),
		CanRestart: s.RequestRestart != nil,
		DNSRows:    strings.Split(values["VPN_DNS"], ","),
	})
}

func (s *Server) restart(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	values, err := s.Accounts.Store.VPNSettings(ctx)
	if err != nil {
		log.Printf("读取待应用的 VPN 设置: %v", err)
		http.Error(w, "读取 VPN 设置失败", http.StatusInternalServerError)
		return
	}
	if maps.Equal(values, s.ActiveSettings) {
		http.Error(w, "没有待应用的 VPN 设置", http.StatusConflict)
		return
	}
	w.WriteHeader(http.StatusAccepted)
	s.RequestRestart()
}

func (s *Server) saveSettings(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "读取表单失败", http.StatusBadRequest)
		return
	}
	input := make(store.VPNSettings, len(settings.Keys))
	for _, key := range settings.Keys {
		input[key] = r.PostForm.Get(key)
	}
	dnsRows := r.PostForm["VPN_DNS"]
	if len(dnsRows) == 0 {
		dnsRows = []string{""}
	}
	var dnsAddresses []string
	for i, row := range dnsRows {
		if strings.Contains(row, ",") {
			render(w, "dashboard.html", page{
				Admin: s.Admin, Preview: s.Preview, Tab: "settings", Settings: input, DNSRows: dnsRows,
				Error: fmt.Sprintf("DNS 第 %d 行只能填写一个 IPv4 地址。", i+1),
			})
			return
		}
		if address := strings.TrimSpace(row); address != "" {
			dnsAddresses = append(dnsAddresses, address)
		}
	}
	input["VPN_DNS"] = strings.Join(dnsAddresses, ",")
	values, err := settings.Parse(input)
	if err != nil {
		render(w, "dashboard.html", page{
			Admin: s.Admin, Preview: s.Preview, Tab: "settings", Error: err.Error(),
			Settings: input, DNSRows: dnsRows,
		})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if err := s.Accounts.Store.SaveVPNSettings(ctx, values); err != nil {
		log.Printf("保存 VPN 设置: %v", err)
		http.Error(w, "保存 VPN 设置失败", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings", http.StatusSeeOther)
}

func (s *Server) traffic(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	sessions, err := s.Accounts.VPN.Sessions(ctx, true)
	if err != nil {
		http.Error(w, "读取会话速度失败", http.StatusServiceUnavailable)
		return
	}
	if sessions == nil {
		sessions = []vpn.Session{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(sessions)
}

func (s *Server) connections(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	sessions, err := s.Accounts.VPN.Sessions(ctx, false)
	if err != nil {
		http.Error(w, "读取连接数失败", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(struct {
		Total  int            `json:"total"`
		Counts map[string]int `json:"counts"`
	}{len(sessions), connectionCounts(sessions)})
}

func connectionCounts(sessions []vpn.Session) map[string]int {
	counts := make(map[string]int)
	for _, session := range sessions {
		counts[strings.ToLower(session.Account)]++
	}
	return counts
}

func render(w http.ResponseWriter, name string, data page) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := pages.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

func (s *Server) auth(next http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.authenticated(r) {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next.ServeHTTP(w, r)
	}
}

const sessionCookie = "ikev2_admin"
const sessionLifetime = 8 * time.Hour

func (s *Server) authenticated(r *http.Request) bool {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return false
	}
	s.sessionMu.Lock()
	defer s.sessionMu.Unlock()
	return time.Now().Before(s.sessions[cookie.Value])
}

func (s *Server) loginPage(w http.ResponseWriter, r *http.Request) {
	if s.authenticated(r) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	render(w, "login.html", page{Preview: s.Preview})
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "表单无效", 400)
		return
	}
	s.loginMu.Lock()
	if time.Now().Before(s.nextLogin) {
		s.loginMu.Unlock()
		w.Header().Set("Retry-After", "2")
		w.WriteHeader(http.StatusTooManyRequests)
		render(w, "login.html", page{Preview: s.Preview, Error: "请求过快，请稍后重试。"})
		return
	}
	s.nextLogin = time.Now().Add(2 * time.Second)
	s.loginMu.Unlock()
	hash, err := accounts.PasswordHash(r.PostForm.Get("password"))
	valid := err == nil && subtle.ConstantTimeCompare(s.PasswordHash, hash) == 1
	if !valid || r.PostForm.Get("username") != s.Admin {
		w.WriteHeader(http.StatusUnauthorized)
		render(w, "login.html", page{Preview: s.Preview, Error: "用户名或密码错误。"})
		return
	}
	var random [32]byte
	rand.Read(random[:])
	token := base64.RawURLEncoding.EncodeToString(random[:])
	now := time.Now()
	s.sessionMu.Lock()
	if s.sessions == nil {
		s.sessions = make(map[string]time.Time)
	}
	for id, expires := range s.sessions {
		if !now.Before(expires) {
			delete(s.sessions, id)
		}
	}
	if old, err := r.Cookie(sessionCookie); err == nil {
		delete(s.sessions, old.Value)
	}
	s.sessions[token] = now.Add(sessionLifetime)
	s.sessionMu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: token, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil, MaxAge: int(sessionLifetime.Seconds())})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.sessionMu.Lock()
		delete(s.sessions, cookie.Value)
		s.sessionMu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil, MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	s.show(w, r, "", r.URL.Query().Get("updated") == "1")
}

func (s *Server) show(w http.ResponseWriter, r *http.Request, problem string, updated bool) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	data := page{Admin: s.Admin, Preview: s.Preview, Tab: "accounts", Error: problem}
	if strings.HasPrefix(r.URL.Path, "/sessions") {
		data.Tab = "sessions"
	}
	if updated {
		data.Notice = "更改已生效。"
	}
	items, err := s.Accounts.Store.Accounts(ctx)
	if err != nil {
		log.Printf("list accounts: %v", err)
		http.Error(w, "读取账号失败", 500)
		return
	}
	sessions, err := s.Accounts.VPN.Sessions(ctx, false)
	if err != nil {
		log.Printf("list VPN sessions: %v", err)
		data.SessionError = true
	}
	data.Sessions = sessions
	counts := connectionCounts(sessions)
	for _, item := range items {
		data.Rows = append(data.Rows, row{item, counts[strings.ToLower(item.Name)]})
		if item.Enabled {
			data.Enabled++
		}
	}
	render(w, "dashboard.html", data)
}

func (s *Server) change(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "表单无效", 400)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	action := r.PostForm.Get("action")
	username := r.PostForm.Get("username")
	var err error
	if action == "limits" {
		values := make([]int, 0, 3)
		for _, key := range []string{"max_sessions", "upload_mbps", "download_mbps"} {
			value, parseErr := strconv.Atoi(r.PostForm.Get(key))
			if parseErr != nil {
				s.show(w, r, "共享数和速率必须填写整数。", false)
				return
			}
			values = append(values, value)
		}
		err = s.Accounts.SetLimits(ctx, username, store.Limits{
			MaxSessions: values[0], UploadMbps: values[1], DownloadMbps: values[2],
		})
	} else {
		err = s.Accounts.Change(ctx, action, username, r.PostForm.Get("password"))
	}
	if err != nil {
		s.show(w, r, err.Error(), false)
		return
	}
	http.Redirect(w, r, "/?updated=1", http.StatusSeeOther)
}
