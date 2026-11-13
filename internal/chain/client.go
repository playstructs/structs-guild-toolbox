// Package chain talks to a Structs node through the structsd binary (so it
// honours the user's keyring, home and node settings) plus the node's
// CometBFT RPC for whole-transaction simulation and block height.
package chain

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Client runs structsd commands. It is safe for concurrent use; at most
// Parallel commands run at once.
type Client struct {
	Bin     string
	Flags   []string // passed to every command: --node, --home, --keyring-backend ...
	TxFlags []string // passed to transactions only: --fees, --gas-prices ...

	// Settings resolved from flags, then <home>/config/client.toml, then
	// structsd's defaults — the same order structsd uses.
	Home           string
	Node           string // tcp://host:26657
	KeyringBackend string // os | file | test | ...
	KeyringDir     string // "" = the home directory
	DefaultKey     string // client.toml keyring-default-keyname
	ConfigFile     string // the client.toml that was read ("" if none)

	chainOnce sync.Once
	chainID   string
	chainErr  error

	sem chan struct{}
}

// New builds a client and reads client.toml for defaults.
func New(bin string, flags, txFlags []string) *Client {
	if bin == "" {
		bin = "structsd"
	}
	c := &Client{Bin: bin, Flags: flags, TxFlags: txFlags, sem: make(chan struct{}, 8)}
	c.Home = flagValue(flags, "--home")
	if c.Home == "" {
		h, _ := os.UserHomeDir()
		c.Home = filepath.Join(h, ".structs")
	}
	path := filepath.Join(c.Home, "config", "client.toml")
	cfg := readClientToml(path)
	if len(cfg) > 0 {
		c.ConfigFile = path
	}
	c.Node = firstNonEmpty(flagValue(flags, "--node"), cfg["node"], "tcp://localhost:26657")
	c.KeyringBackend = firstNonEmpty(flagValue(flags, "--keyring-backend"), cfg["keyring-backend"], "os")
	c.KeyringDir = flagValue(flags, "--keyring-dir")
	c.DefaultKey = cfg["keyring-default-keyname"]
	c.chainID = firstNonEmpty(flagValue(flags, "--chain-id"), cfg["chain-id"])
	return c
}

// keyringFlags pins every keyring-touching command (keys, tx) to the keyring
// resolved above, so the app and structsd can never disagree about it.
func (c *Client) keyringFlags() []string {
	out := append([]string{}, c.Flags...)
	if flagValue(c.Flags, "--home") == "" {
		out = append(out, "--home", c.Home)
	}
	if flagValue(c.Flags, "--keyring-backend") == "" {
		out = append(out, "--keyring-backend", c.KeyringBackend)
	}
	return out
}

// KeyringLabel describes where keys come from: "test keyring in ~/.structs".
func (c *Client) KeyringLabel() string {
	dir := c.KeyringDir
	if dir == "" {
		dir = c.Home
	}
	if h, err := os.UserHomeDir(); err == nil && strings.HasPrefix(dir, h) {
		dir = "~" + strings.TrimPrefix(dir, h)
	}
	label := c.KeyringBackend + " keyring in " + dir
	if c.KeyringBackend == "os" {
		label = "OS keychain (structs)" // the os backend lives in the system keychain
	}
	return label
}

func flagValue(flags []string, name string) string {
	for i, f := range flags {
		if f == name && i+1 < len(flags) {
			return flags[i+1]
		}
		if strings.HasPrefix(f, name+"=") {
			return strings.TrimPrefix(f, name+"=")
		}
	}
	return ""
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

func readClientToml(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.HasPrefix(line, "#") {
			continue
		}
		out[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"`)
	}
	return out
}

// CommandError carries structsd's stderr in a readable form.
type CommandError struct {
	Args   []string
	Stderr string
	Err    error
}

func (e *CommandError) Error() string {
	msg := cleanCLIError(e.Stderr)
	if msg == "" && e.Err != nil {
		msg = e.Err.Error()
	}
	return msg
}

// cleanCLIError strips cobra usage dumps and SDK wrapping from structsd output.
func cleanCLIError(s string) string {
	var keep []string
	for _, line := range strings.Split(s, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(line, "  ") || strings.HasPrefix(t, "Usage:") ||
			strings.HasPrefix(t, "Flags:") || strings.HasPrefix(t, "Global Flags:") ||
			strings.HasPrefix(t, "gas estimate:") || strings.Contains(t, "for more information about a command") {
			continue
		}
		keep = append(keep, t)
	}
	return Humanize(strings.Join(keep, " "))
}

// Humanize trims Cosmos SDK error noise:
// "rpc error: code = Unknown desc = failed to execute message; message index: 1: spendable balance ... [cosmos/...]"
// -> "step 2: spendable balance ..."
func Humanize(msg string) string {
	msg = strings.TrimSpace(msg)
	for _, p := range []string{"rpc error: code = Unknown desc = ", "rpc error: code = InvalidArgument desc = ", "Error: "} {
		msg = strings.ReplaceAll(msg, p, "")
	}
	if i := strings.Index(msg, "failed to execute message; message index: "); i >= 0 {
		rest := msg[i+len("failed to execute message; message index: "):]
		idx, after, ok := strings.Cut(rest, ": ")
		if ok {
			var n int
			fmt.Sscanf(idx, "%d", &n)
			msg = fmt.Sprintf("step %d: %s", n+1, after)
		}
	}
	if i := strings.Index(msg, " [cosmos/"); i >= 0 {
		msg = msg[:i]
	}
	if i := strings.Index(msg, " with gas used"); i >= 0 {
		msg = msg[:i]
	}
	return strings.TrimSpace(msg)
}

func (c *Client) run(ctx context.Context, stdin string, args ...string) ([]byte, error) {
	select {
	case c.sem <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-c.sem }()
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	err := cmd.Run()
	if err != nil {
		// structsd sometimes reports errors on stdout
		se := stderr.String()
		if strings.TrimSpace(se) == "" {
			se = stdout.String()
		}
		return stdout.Bytes(), &CommandError{Args: args, Stderr: se, Err: err}
	}
	return stdout.Bytes(), nil
}

// lastJSON returns the last top-level JSON object in the output (structsd
// may print notices such as "gas estimate: N" before it, and may indent it).
func lastJSON(b []byte) []byte {
	t := bytes.TrimSpace(b)
	if i := bytes.LastIndex(t, []byte("\n{")); i >= 0 {
		return t[i+1:]
	}
	if len(t) > 0 && t[0] == '{' {
		return t
	}
	if i := bytes.IndexByte(t, '{'); i >= 0 {
		return t[i:]
	}
	return t
}

// Query runs `structsd query <args> --output json` and decodes into out.
func (c *Client) Query(ctx context.Context, out any, args ...string) error {
	full := append(append([]string{"query"}, args...), "--output", "json")
	full = append(full, c.Flags...)
	b, err := c.run(ctx, "", full...)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(lastJSON(b), out); err != nil {
		return fmt.Errorf("decoding %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

// QueryAll walks every page of a paginated query, decoding the array at key.
//
// Some structs queries (address-all-by-player) filter within each page of a
// global index, so early pages can be empty while later ones are not — always
// follow next_key to the end.
func QueryAll[T any](ctx context.Context, c *Client, key string, args ...string) ([]T, error) {
	var all []T
	pageKey := ""
	for guard := 0; guard < 1000; guard++ {
		a := append([]string{}, args...)
		a = append(a, "--page-limit", "1000")
		if pageKey != "" {
			a = append(a, "--page-key", pageKey)
		}
		var raw map[string]json.RawMessage
		if err := c.Query(ctx, &raw, a...); err != nil {
			return all, err
		}
		if arr, ok := raw[key]; ok && string(arr) != "null" {
			var items []T
			if err := json.Unmarshal(arr, &items); err != nil {
				return all, fmt.Errorf("decoding %s: %w", key, err)
			}
			all = append(all, items...)
		}
		var pg struct {
			NextKey string `json:"next_key"`
		}
		if p, ok := raw["pagination"]; ok {
			_ = json.Unmarshal(p, &pg)
		}
		if pg.NextKey == "" {
			return all, nil
		}
		pageKey = pg.NextKey
	}
	return all, errors.New("pagination did not terminate")
}

// ChainID returns the configured or detected chain id.
func (c *Client) ChainID(ctx context.Context) (string, error) {
	c.chainOnce.Do(func() {
		if c.chainID != "" {
			return
		}
		st, err := c.Status(ctx)
		if err != nil {
			c.chainErr = fmt.Errorf("could not reach the node at %s: %w", c.Node, err)
			return
		}
		c.chainID = st.Network
	})
	return c.chainID, c.chainErr
}

// NodeStatus is the bit of CometBFT status we use.
type NodeStatus struct {
	Network    string
	Height     int64
	Time       time.Time
	CatchingUp bool
}

// Status asks the node's RPC directly (fast; no process spawn).
func (c *Client) Status(ctx context.Context) (NodeStatus, error) {
	var r struct {
		Result struct {
			NodeInfo struct {
				Network string `json:"network"`
			} `json:"node_info"`
			SyncInfo struct {
				Height     string    `json:"latest_block_height"`
				Time       time.Time `json:"latest_block_time"`
				CatchingUp bool      `json:"catching_up"`
			} `json:"sync_info"`
		} `json:"result"`
	}
	if err := c.rpcGet(ctx, "/status", &r); err != nil {
		return NodeStatus{}, err
	}
	var h int64
	fmt.Sscanf(r.Result.SyncInfo.Height, "%d", &h)
	return NodeStatus{Network: r.Result.NodeInfo.Network, Height: h, Time: r.Result.SyncInfo.Time, CatchingUp: r.Result.SyncInfo.CatchingUp}, nil
}

// ---- keys ----

type Key struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Address string `json:"address"`
	PubKey  string `json:"pubkey"` // JSON: {"@type": "...", "key": "..."}
}

func (c *Client) Keys(ctx context.Context) ([]Key, error) {
	b, err := c.run(ctx, "", append([]string{"keys", "list", "--output", "json"}, c.keyringFlags()...)...)
	if err != nil {
		return nil, err
	}
	var keys []Key
	if err := json.Unmarshal(lastJSONArray(b), &keys); err != nil {
		return nil, err
	}
	return keys, nil
}

func (c *Client) Key(ctx context.Context, name string) (Key, error) {
	b, err := c.run(ctx, "", append([]string{"keys", "show", name, "--output", "json"}, c.keyringFlags()...)...)
	if err != nil {
		return Key{}, err
	}
	var k Key
	err = json.Unmarshal(lastJSON(b), &k)
	return k, err
}

func lastJSONArray(b []byte) []byte {
	t := bytes.TrimSpace(b)
	if i := bytes.IndexByte(t, '['); i >= 0 {
		return t[i:]
	}
	return t
}
