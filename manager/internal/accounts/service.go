package accounts

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
	"unicode/utf16"
	"unicode/utf8"

	"golang.org/x/crypto/md4"
	"ikev2/manager/internal/store"
	"ikev2/manager/internal/vpn"
)

var validName = regexp.MustCompile("^[a-zA-Z0-9_.@-]+$")

func ValidName(name string) bool { return len(name) <= 255 && validName.MatchString(name) }

func PasswordHash(password string) ([]byte, error) {
	if password == "" || !utf8.ValidString(password) || strings.ContainsAny(password, "\r\n\x00") {
		return nil, errors.New("密码不能为空，且必须是有效文本")
	}
	units := utf16.Encode([]rune(password))
	data := make([]byte, len(units)*2)
	for i, unit := range units {
		binary.LittleEndian.PutUint16(data[2*i:], unit)
	}
	hash := md4.New()
	hash.Write(data)
	return hash.Sum(nil), nil
}

func ReadUsers(r io.Reader) ([]store.Account, error) {
	scanner := bufio.NewScanner(r)
	var accounts []store.Account
	for line := 1; scanner.Scan(); line++ {
		value := scanner.Text()
		if line == 1 {
			value = strings.TrimPrefix(value, "\ufeff")
		}
		if trimmed := strings.TrimSpace(value); trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		name, password, ok := strings.Cut(value, ":")
		if !ok || !ValidName(name) {
			return nil, fmt.Errorf("账号文件第 %d 行格式无效", line)
		}
		var hash []byte
		var err error
		if nt, ok := strings.CutPrefix(password, "{NT}"); ok {
			hash, err = hex.DecodeString(nt)
		} else {
			hash, err = PasswordHash(password)
		}
		if err != nil || len(hash) != 16 {
			return nil, fmt.Errorf("账号文件第 %d 行密码或 NT 哈希无效", line)
		}
		accounts = append(accounts, store.Account{Name: name, Hash: hash, Enabled: true})
	}
	return accounts, scanner.Err()
}

type Service struct {
	Store *store.Store
	VPN   vpn.Gateway
	mu    sync.Mutex
}

func (s *Service) ApplyAll(ctx context.Context, items []store.Account) error {
	for _, account := range items {
		if err := s.apply(ctx, account); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) Change(ctx context.Context, action, name, password string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !ValidName(name) {
		return errors.New("用户名只能包含字母、数字和 _ . @ -")
	}
	var account store.Account
	if action == "add" {
		hash, err := PasswordHash(password)
		if err != nil {
			return err
		}
		account = store.Account{Name: name, Hash: hash, Enabled: true}
		if err := s.Store.Add(ctx, account); err != nil {
			return err
		}
	} else {
		var err error
		account, err = s.Store.Account(ctx, name)
		if err != nil {
			return err
		}
		switch action {
		case "reset":
			account.Hash, err = PasswordHash(password)
			if err != nil {
				return err
			}
		case "enable":
			account.Enabled = true
		case "disable":
			account.Enabled = false
		case "apply":
			return s.apply(ctx, account)
		default:
			return errors.New("未知的账号操作")
		}
		if err := s.Store.Update(ctx, account); err != nil {
			return err
		}
	}
	return s.apply(ctx, account)
}

func (s *Service) apply(ctx context.Context, account store.Account) error {
	if err := s.VPN.Apply(ctx, account); err != nil {
		return fmt.Errorf("已保存 %s，但 VPN 应用失败: %w", account.Name, err)
	}
	return s.Store.Applied(ctx, account.Name)
}

func (s *Service) SetLimits(ctx context.Context, name string, limits store.Limits) error {
	if limits.MaxSessions < 0 || limits.MaxSessions > 65535 ||
		limits.UploadMbps < 0 || limits.UploadMbps > 10000 ||
		limits.DownloadMbps < 0 || limits.DownloadMbps > 10000 {
		return errors.New("共享数须在 0–65535 之间，速率须在 0–10000 Mbps 之间")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	account, err := s.Store.Account(ctx, name)
	if err != nil {
		return err
	}
	account.Limits = limits
	if err := s.Store.Update(ctx, account); err != nil {
		return err
	}
	return s.apply(ctx, account)
}
