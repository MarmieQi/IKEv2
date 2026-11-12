package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"ikev2/manager/internal/accounts"
	"ikev2/manager/internal/settings"
	"ikev2/manager/internal/store"
	"ikev2/manager/internal/vpn"
	"ikev2/manager/internal/web"
)

func TestManagedAccounts(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "manager.db")
	db, err := store.Open(path, "admin")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	vpnAccounts := []store.Account{
		{Name: "old", Hash: make([]byte, 16)},
		{Name: "second", Hash: make([]byte, 16)},
	}
	hash, err := accounts.PasswordHash("test-admin-password")
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Prepare(ctx); err != nil {
		t.Fatal(err)
	}
	for _, item := range vpnAccounts {
		if err := db.Add(ctx, item); err != nil {
			t.Fatal(err)
		}
		if err := db.Applied(ctx, item.Name); err != nil {
			t.Fatal(err)
		}
	}
	gateway := &previewVPN{items: []vpn.Session{
		{ID: "1", Account: "old"}, {ID: "2", Account: "second"},
	}}
	service := &accounts.Service{Store: db, VPN: gateway}
	initial := store.VPNSettings{"VPN_DOMAIN": "vpn.example.com", "VPN_DNS": "1.1.1.1", "VPN_ROUTES": "0.0.0.0/0"}
	active, err := settings.LoadOrSeed(ctx, db, func() (store.VPNSettings, error) { return initial, nil })
	if err != nil {
		t.Fatal(err)
	}
	handler := (&web.Server{Accounts: service, Admin: "admin", PasswordHash: hash, ActiveSettings: active, Preview: true}).Handler()

	send := func(method, path string, form url.Values, cookie *http.Cookie) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if method == "POST" {
			request.Header.Set("Origin", "http://"+request.Host)
		}
		if cookie != nil {
			request.AddCookie(cookie)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	for _, endpoint := range []struct{ method, path string }{
		{"GET", "/"}, {"GET", "/settings"}, {"GET", "/sessions"}, {"GET", "/sessions/traffic"},
		{"POST", "/settings"}, {"POST", "/accounts"}, {"POST", "/sessions/disconnect"}, {"POST", "/logout"},
	} {
		response := send(endpoint.method, endpoint.path, nil, nil)
		if response.Code != 303 || response.Header().Get("Location") != "/login" {
			t.Fatalf("anonymous %s %s was not redirected to login", endpoint.method, endpoint.path)
		}
	}
	loginPage := send("GET", "/login", nil, nil)
	if loginPage.Header().Get("Referrer-Policy") != "same-origin" {
		t.Fatal("login page must preserve Origin for same-origin form submissions")
	}
	login := send("POST", "/login", url.Values{"username": {"admin"}, "password": {"test-admin-password"}}, nil)
	if login.Code != 303 || len(login.Result().Cookies()) != 1 {
		t.Fatalf("login failed: %d", login.Code)
	}
	cookie := login.Result().Cookies()[0]
	crossSite := httptest.NewRequest("POST", "/accounts", nil)
	crossSite.Header.Set("Sec-Fetch-Site", "cross-site")
	crossSite.AddCookie(cookie)
	denied := httptest.NewRecorder()
	handler.ServeHTTP(denied, crossSite)
	if denied.Code != http.StatusForbidden {
		t.Fatal("cross-site account change was not blocked")
	}
	form := url.Values{
		"VPN_DOMAIN": {"vpn2.example.com"}, "VPN_MODE": {"proxyarp"},
		"VPN_DNS": {"9.9.9.9", "8.8.8.8"}, "VPN_ROUTES": {"192.168.0.0/24"},
		"PROXYARP_POOL": {"192.168.0.201-192.168.0.210"}, "PROXYARP_GATEWAY": {"192.168.0.4"},
	}
	if response := send("POST", "/settings", form, cookie); response.Code != 303 {
		t.Fatalf("saving VPN settings failed: %d", response.Code)
	}
	if response := send("GET", "/settings", nil, cookie); !strings.Contains(response.Body.String(), "待重启生效") {
		t.Fatal("saved settings should be pending until restart")
	}
	form.Set("VPN_ROUTES", "192.168.0.1/24")
	send("POST", "/settings", form, cookie)
	saved, err := settings.LoadOrSeed(ctx, db, func() (store.VPNSettings, error) {
		t.Fatal("saved settings should not read .env")
		return nil, nil
	})
	if err != nil || saved["VPN_DOMAIN"] != "vpn2.example.com" || saved["VPN_MODE"] != "proxyarp" ||
		saved["VPN_DNS"] != "9.9.9.9,8.8.8.8" || saved["VPN_ROUTES"] != "192.168.0.0/24" ||
		saved["PROXYARP_GATEWAY"] != "192.168.0.4" {
		t.Fatalf("invalid save or stale env changed saved settings: %+v, %v", saved, err)
	}
	for _, change := range []url.Values{
		{"action": {"add"}, "username": {"new"}, "password": {"password"}},
		{"action": {"reset"}, "username": {"new"}, "password": {"new-password"}},
		{"action": {"disable"}, "username": {"old"}},
	} {
		if response := send("POST", "/accounts", change, cookie); response.Code != 303 {
			t.Fatalf("account action %s failed: %d", change.Get("action"), response.Code)
		}
	}
	old, err := db.Account(ctx, "old")
	if err != nil || old.Enabled || old.Pending {
		t.Fatalf("unexpected persisted disabled state: enabled=%v pending=%v error=%v", old.Enabled, old.Pending, err)
	}
	sessions, err := gateway.Sessions(ctx)
	if err != nil || len(sessions) != 1 || sessions[0].ID != "2" {
		t.Fatal("disabling old account should disconnect only its session")
	}
	if response := send("POST", "/sessions/disconnect", url.Values{"id": {"2"}}, cookie); response.Code != 303 {
		t.Fatalf("disconnect failed: %d", response.Code)
	}
	if response := send("GET", "/sessions", nil, cookie); response.Code != 200 || !strings.Contains(response.Body.String(), "当前没有在线连接") {
		t.Fatal("session page did not show empty state")
	}
	if response := send("POST", "/logout", nil, cookie); response.Header().Get("Location") != "/login" {
		t.Fatal("logout did not redirect to login")
	}
	if response := send("GET", "/settings", nil, cookie); response.Code != 303 || response.Header().Get("Location") != "/login" {
		t.Fatal("logged-out session could still read settings")
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = store.Open(path, "admin")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	account, err := db.Account(ctx, "new")
	expected, _ := accounts.PasswordHash("new-password")
	if err != nil || !account.Enabled || account.Pending || hex.EncodeToString(account.Hash) != hex.EncodeToString(expected) {
		t.Fatal("new credentials did not survive reopening SQLite")
	}
	if err := db.Add(ctx, store.Account{Name: "ADMIN", Hash: expected}); err == nil {
		t.Fatal("administrator name was accepted as a VPN account")
	}
}

func TestPrepareRemovesStoredAdministrator(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "manager.db")
	db, err := store.Open(path, "admin")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Prepare(ctx); err != nil {
		t.Fatal(err)
	}
	if err := db.Add(ctx, store.Account{Name: "vpn-user", Hash: make([]byte, 16)}); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if _, err := raw.ExecContext(ctx, "CREATE TABLE admin (password_hash BLOB); INSERT INTO admin VALUES (x'001122'); CREATE TABLE admin_names (name TEXT)"); err != nil {
		t.Fatal(err)
	}
	if err := db.Prepare(ctx); err != nil {
		t.Fatal(err)
	}
	var count int
	err = raw.QueryRowContext(ctx, "SELECT count(*) FROM sqlite_schema WHERE name IN ('admin', 'admin_names')").Scan(&count)
	if err != nil || count != 0 {
		t.Fatalf("legacy administrator tables remain: %d, %v", count, err)
	}
	if _, err := db.Account(ctx, "vpn-user"); err != nil {
		t.Fatal(err)
	}
}

func TestReadAdmin(t *testing.T) {
	for _, contents := range []string{
		"\ufeff# admin\r\nadmin:password\r\n",
		"admin:{NT}8846F7EAEE8FB117AD06BDD830B7586C\n",
	} {
		name, hash, err := readAdmin(strings.NewReader(contents))
		if err != nil || name != "admin" || hex.EncodeToString(hash) != "8846f7eaee8fb117ad06bdd830b7586c" {
			t.Fatalf("failed to read administrator credentials: %v", err)
		}
	}
	if _, _, err := readAdmin(strings.NewReader("admin:password\nvpn-user:password\n")); err == nil {
		t.Fatal("accepted more than one administrator entry")
	}
}
