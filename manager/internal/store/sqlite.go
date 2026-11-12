package store

import (
	"context"
	"database/sql"
	"errors"
	"net/url"
	"os"

	_ "modernc.org/sqlite"
)

type Account struct {
	Limits
	Name    string
	Hash    []byte
	Enabled bool
	Pending bool
}

type Limits struct {
	MaxSessions  int
	UploadMbps   int
	DownloadMbps int
}

type Store struct{ db *sql.DB }

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
    name TEXT PRIMARY KEY COLLATE NOCASE,
    nt_hash BLOB NOT NULL CHECK (length(nt_hash) = 16),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    pending INTEGER NOT NULL CHECK (pending IN (0, 1)),
    max_sessions INTEGER NOT NULL DEFAULT 0 CHECK (max_sessions BETWEEN 0 AND 65535),
    upload_mbps INTEGER NOT NULL DEFAULT 0 CHECK (upload_mbps BETWEEN 0 AND 10000),
    download_mbps INTEGER NOT NULL DEFAULT 0 CHECK (download_mbps BETWEEN 0 AND 10000)
);
CREATE TABLE IF NOT EXISTS vpn_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    configuration TEXT NOT NULL
);`

func Open(path string) (*Store, error) {
	dsn := ":memory:"
	if path != ":memory:" {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			return nil, err
		}
		if err := file.Close(); err != nil {
			return nil, err
		}
		location := url.URL{Scheme: "file", Opaque: path, RawQuery: "mode=rw"}
		dsn = location.String()
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) Prepare(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, schema); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Accounts(ctx context.Context) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT name, nt_hash, enabled, pending, max_sessions, upload_mbps, download_mbps FROM accounts ORDER BY rowid")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var accounts []Account
	for rows.Next() {
		var account Account
		if err := rows.Scan(&account.Name, &account.Hash, &account.Enabled, &account.Pending, &account.MaxSessions, &account.UploadMbps, &account.DownloadMbps); err != nil {
			return nil, err
		}
		accounts = append(accounts, account)
	}
	return accounts, rows.Err()
}

func (s *Store) Account(ctx context.Context, name string) (Account, error) {
	var account Account
	err := s.db.QueryRowContext(ctx, "SELECT name, nt_hash, enabled, pending, max_sessions, upload_mbps, download_mbps FROM accounts WHERE name = ?", name).
		Scan(&account.Name, &account.Hash, &account.Enabled, &account.Pending, &account.MaxSessions, &account.UploadMbps, &account.DownloadMbps)
	return account, err
}

func (s *Store) Add(ctx context.Context, account Account) error {
	result, err := s.db.ExecContext(ctx, `INSERT INTO accounts (name, nt_hash, enabled, pending)
VALUES (?, ?, 1, 1)
ON CONFLICT(name) DO NOTHING`, account.Name, account.Hash)
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err == nil && changed == 0 {
		return errors.New("VPN 用户名已存在")
	}
	return err
}

func (s *Store) Update(ctx context.Context, account Account) error {
	_, err := s.db.ExecContext(ctx, "UPDATE accounts SET nt_hash = ?, enabled = ?, pending = 1, max_sessions = ?, upload_mbps = ?, download_mbps = ? WHERE name = ?", account.Hash, account.Enabled, account.MaxSessions, account.UploadMbps, account.DownloadMbps, account.Name)
	return err
}

func (s *Store) Applied(ctx context.Context, name string) error {
	_, err := s.db.ExecContext(ctx, "UPDATE accounts SET pending = 0 WHERE name = ?", name)
	return err
}
