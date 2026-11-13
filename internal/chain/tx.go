package chain

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Msg is the argument list for one `structsd tx` message, e.g.
// Msg{"structs", "player-send", from, to, "100ualpha"}.
type Msg []string

func (m Msg) String() string { return strings.Join(m, " ") }

// Prepared is an unsigned transaction holding one or more messages, already
// simulated against current chain state as a single unit.
type Prepared struct {
	Msgs     []Msg
	Unsigned map[string]any
	GasUsed  uint64
	GasLimit uint64
}

// Signer is the key that signs.
type Signer struct {
	Name    string
	Address string
	PubKey  string // JSON {"@type": ..., "key": ...}
}

// Prepare builds every message with --generate-only, merges them into one
// transaction and simulates the whole thing. Messages are applied in order,
// so a later message may depend on an earlier one (e.g. move tokens into the
// vault, then redeem them).
func (c *Client) Prepare(ctx context.Context, s Signer, msgs []Msg) (*Prepared, error) {
	if len(msgs) == 0 {
		return nil, errors.New("nothing to do")
	}
	chainID, err := c.ChainID(ctx)
	if err != nil {
		return nil, err
	}
	gens := make([]map[string]any, len(msgs))
	errs := make([]error, len(msgs))
	var wg sync.WaitGroup
	for i, m := range msgs {
		wg.Add(1)
		go func(i int, m Msg) {
			defer wg.Done()
			args := append([]string{"tx"}, m...)
			args = append(args, "--from", s.Name, "--generate-only", "--chain-id", chainID)
			args = append(args, c.keyringFlags()...)
			args = append(args, c.TxFlags...)
			out, err := c.run(ctx, c.keyStdin(), args...)
			if err != nil {
				errs[i] = fmt.Errorf("step %d (%s): %w", i+1, m[1], err)
				return
			}
			var tx map[string]any
			if err := json.Unmarshal(lastJSON(out), &tx); err != nil {
				errs[i] = fmt.Errorf("step %d: unexpected output: %s", i+1, strings.TrimSpace(string(out)))
				return
			}
			gens[i] = tx
		}(i, m)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}

	merged := gens[0]
	body := merged["body"].(map[string]any)
	all, _ := body["messages"].([]any)
	for _, g := range gens[1:] {
		more, _ := g["body"].(map[string]any)["messages"].([]any)
		all = append(all, more...)
	}
	body["messages"] = all

	p := &Prepared{Msgs: msgs, Unsigned: merged}
	used, err := c.simulate(ctx, s, merged)
	if err != nil {
		return p, err
	}
	p.GasUsed = used
	p.GasLimit = used*14/10 + 20000
	merged["auth_info"].(map[string]any)["fee"].(map[string]any)["gas_limit"] = fmt.Sprint(p.GasLimit)
	return p, nil
}

func (c *Client) simulate(ctx context.Context, s Signer, unsigned map[string]any) (uint64, error) {
	var pk map[string]any
	if err := json.Unmarshal([]byte(s.PubKey), &pk); err != nil {
		return 0, fmt.Errorf("signing key has no readable public key: %w", err)
	}
	seq, err := c.AccountSequence(ctx, s.Address)
	if err != nil {
		// brand-new account: sequence 0
		seq = "0"
	}
	sim := deepCopy(unsigned)
	ai := sim["auth_info"].(map[string]any)
	ai["signer_infos"] = []any{map[string]any{
		"public_key": pk,
		"mode_info":  map[string]any{"single": map[string]any{"mode": "SIGN_MODE_DIRECT"}},
		"sequence":   seq,
	}}
	sim["signatures"] = []any{""}

	dir, err := os.MkdirTemp("", "structs-tx-")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)
	f := filepath.Join(dir, "sim.json")
	if err := writeJSON(f, sim); err != nil {
		return 0, err
	}
	out, err := c.run(ctx, "", append([]string{"tx", "encode", f}, c.homeFlags()...)...)
	if err != nil {
		return 0, err
	}
	txBytes, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		return 0, fmt.Errorf("encoding transaction: %w", err)
	}
	return c.simulateTxBytes(ctx, txBytes)
}

// homeFlags is the subset of flags every structsd subcommand accepts.
func (c *Client) homeFlags() []string {
	if h := flagValue(c.Flags, "--home"); h != "" {
		return []string{"--home", h}
	}
	return nil
}

// TxResult is the outcome of a broadcast transaction.
type TxResult struct {
	Hash   string
	Height int64
	Code   int
	Log    string
}

func (r TxResult) OK() bool { return r.Code == 0 }

// SignAndBroadcast signs a prepared transaction with the signer's key and
// broadcasts it. The keyring passphrase, if one is needed, comes from
// SetPassphrase (see keyring.go).
func (c *Client) SignAndBroadcast(ctx context.Context, s Signer, p *Prepared) (string, error) {
	chainID, err := c.ChainID(ctx)
	if err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp("", "structs-tx-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	unsigned, signed := filepath.Join(dir, "unsigned.json"), filepath.Join(dir, "signed.json")
	if err := writeJSON(unsigned, p.Unsigned); err != nil {
		return "", err
	}
	args := append([]string{"tx", "sign", unsigned, "--from", s.Name, "--chain-id", chainID, "--output-document", signed}, c.keyringFlags()...)
	if _, err := c.run(ctx, c.keyStdin(), args...); err != nil {
		return "", fmt.Errorf("signing: %w", err)
	}
	out, err := c.run(ctx, "", append([]string{"tx", "broadcast", signed, "--output", "json"}, c.Flags...)...)
	if err != nil {
		return "", fmt.Errorf("broadcast: %w", err)
	}
	var r struct {
		TxHash string `json:"txhash"`
		Code   int    `json:"code"`
		RawLog string `json:"raw_log"`
	}
	if err := json.Unmarshal(lastJSON(out), &r); err != nil {
		return "", fmt.Errorf("broadcast: unexpected output: %s", strings.TrimSpace(string(out)))
	}
	if r.Code != 0 {
		return r.TxHash, errors.New(Humanize(r.RawLog))
	}
	return r.TxHash, nil
}

// WaitTx polls until the transaction is in a block (or ctx expires).
func (c *Client) WaitTx(ctx context.Context, hash string) (TxResult, error) {
	tick := time.NewTicker(1500 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return TxResult{Hash: hash}, fmt.Errorf("not confirmed yet (check later: structsd query tx %s)", hash)
		case <-tick.C:
			var r struct {
				Height string `json:"height"`
				Code   int    `json:"code"`
				RawLog string `json:"raw_log"`
			}
			if err := c.Query(ctx, &r, "tx", hash); err != nil {
				continue
			}
			var h int64
			fmt.Sscanf(r.Height, "%d", &h)
			res := TxResult{Hash: hash, Height: h, Code: r.Code, Log: Humanize(r.RawLog)}
			if r.Code != 0 {
				return res, errors.New(res.Log)
			}
			return res, nil
		}
	}
}

func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

func deepCopy(m map[string]any) map[string]any {
	b, _ := json.Marshal(m)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}
