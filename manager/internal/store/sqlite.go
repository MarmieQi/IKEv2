package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
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
CREATE TABLE admin (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    name TEXT NOT NULL,
    password_hash BLOB NOT NULL
);
CREATE TABLE accounts (
    name TEXT PRIMARY KEY COLLATE NOCASE,
    nt_hash BLOB NOT NULL CHECK (length(nt_hash) = 16),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    pending INTEGER NOT NULL CHECK (pending IN (0, 1))
);`

func Open(path string) (*Store, error) {
	dsn := ":memory:"
	if path != ":memory:" {
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

func (s *Store) Init(ctx context.Context, name string, passwordHash []byte, accounts []Account) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, schema); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO admin VALUES (1, ?, ?)", name, passwordHash); err != nil {
		return err
	}
	for _, account := range accounts {
		if _, err := tx.ExecContext(ctx, "INSERT INTO accounts (name, nt_hash, enabled, pending) VALUES (?, ?, 1, 0)", account.Name, account.Hash); err != nil {
			return fmt.Errorf("导入账号 %s: %w", account.Name, err)
		}
	}
	if err := migrate(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Admin(ctx context.Context) (string, []byte, error) {
	var name string
	var hash []byte
	err := s.db.QueryRowContext(ctx, "SELECT name, password_hash FROM admin WHERE id = 1").Scan(&name, &hash)
	return name, hash, err
}

func (s *Store) Accounts(ctx context.Context) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT name, nt_hash, enabled, pending, max_sessions, upload_mbps, download_mbps FROM accounts WHERE name NOT IN (SELECT name FROM admin_names) ORDER BY name")
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
	err := s.db.QueryRowContext(ctx, "SELECT name, nt_hash, enabled, pending, max_sessions, upload_mbps, download_mbps FROM accounts WHERE name = ? AND name NOT IN (SELECT name FROM admin_names)", name).
		Scan(&account.Name, &account.Hash, &account.Enabled, &account.Pending, &account.MaxSessions, &account.UploadMbps, &account.DownloadMbps)
	return account, err
}

func (s *Store) Add(ctx context.Context, account Account) error {
	result, err := s.db.ExecContext(ctx, `INSERT INTO accounts (name, nt_hash, enabled, pending)
SELECT ?, ?, 1, 1 WHERE NOT EXISTS (SELECT 1 FROM admin_names WHERE name = ?)
ON CONFLICT(name) DO NOTHING`, account.Name, account.Hash, account.Name)
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err == nil && changed == 0 {
		return errors.New("用户名已存在或保留给后台管理员")
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

func CreateFile(path string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	return file.Close()
}

func (s *Store) Migrate(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := migrate(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}

func migrate(ctx context.Context, tx *sql.Tx) error {
	var version int
	if err := tx.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	switch version {
	case 4:
		return nil
	case 0:
		_, err := tx.ExecContext(ctx, `
ALTER TABLE accounts ADD COLUMN max_sessions INTEGER NOT NULL DEFAULT 0 CHECK (max_sessions BETWEEN 0 AND 65535);
ALTER TABLE accounts ADD COLUMN upload_mbps INTEGER NOT NULL DEFAULT 0 CHECK (upload_mbps BETWEEN 0 AND 10000);
ALTER TABLE accounts ADD COLUMN download_mbps INTEGER NOT NULL DEFAULT 0 CHECK (download_mbps BETWEEN 0 AND 10000);
PRAGMA user_version = 1;`)
		if err != nil {
			return err
		}
		fallthrough
	case 1:
		_, err := tx.ExecContext(ctx, `CREATE TABLE admin_names (name TEXT PRIMARY KEY COLLATE NOCASE);
PRAGMA user_version = 2;`)
		if err != nil {
			return err
		}
		fallthrough
	case 2:
		_, err := tx.ExecContext(ctx, `CREATE TABLE vpn_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    dns TEXT NOT NULL,
    routes TEXT NOT NULL
);
PRAGMA user_version = 3;`)
		if err != nil {
			return err
		}
		fallthrough
	case 3:
		_, err := tx.ExecContext(ctx, `ALTER TABLE vpn_settings RENAME TO vpn_settings_old;
CREATE TABLE vpn_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    configuration TEXT NOT NULL
);
INSERT INTO vpn_settings SELECT id, json_object('VPN_DNS', dns, 'VPN_ROUTES', routes) FROM vpn_settings_old;
DROP TABLE vpn_settings_old;
PRAGMA user_version = 4;`)
		return err
	default:
		return fmt.Errorf("不支持的账号数据库版本 %d", version)
	}
}

func (s *Store) ReserveAdminNames(ctx context.Context, admin string, configured []Account) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO admin_names VALUES (?)", admin); err != nil {
		return err
	}
	for _, account := range configured {
		if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO admin_names VALUES (?)", account.Name); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, "UPDATE accounts SET enabled = 0, pending = 0 WHERE enabled = 1 AND name IN (SELECT name FROM admin_names)"); err != nil {
		return err
	}
	return tx.Commit()
}
