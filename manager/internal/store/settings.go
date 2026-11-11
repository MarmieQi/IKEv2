package store

import (
	"context"
	"encoding/json"
)

type VPNSettings map[string]string

func (s *Store) VPNSettings(ctx context.Context) (VPNSettings, error) {
	var raw string
	err := s.db.QueryRowContext(ctx, "SELECT configuration FROM vpn_settings WHERE id = 1").Scan(&raw)
	if err != nil {
		return nil, err
	}
	var values VPNSettings
	err = json.Unmarshal([]byte(raw), &values)
	return values, err
}

func (s *Store) SeedVPNSettings(ctx context.Context, values VPNSettings) error {
	raw, err := json.Marshal(values)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, "INSERT INTO vpn_settings VALUES (1, ?) ON CONFLICT(id) DO NOTHING", string(raw))
	return err
}

func (s *Store) SaveVPNSettings(ctx context.Context, values VPNSettings) error {
	raw, err := json.Marshal(values)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO vpn_settings VALUES (1, ?)
ON CONFLICT(id) DO UPDATE SET configuration = excluded.configuration`, string(raw))
	return err
}
