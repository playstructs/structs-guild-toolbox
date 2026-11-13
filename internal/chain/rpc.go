package chain

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 20 * time.Second}

func (c *Client) rpcURL() string {
	u := c.Node
	u = strings.Replace(u, "tcp://", "http://", 1)
	if !strings.HasPrefix(u, "http") {
		u = "http://" + u
	}
	return strings.TrimRight(u, "/")
}

func (c *Client) rpcGet(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, "GET", c.rpcURL()+path, nil)
	if err != nil {
		return err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) rpcCall(ctx context.Context, method string, params any, out any) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	req, err := http.NewRequestWithContext(ctx, "POST", c.rpcURL(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

// abciQuery runs a gRPC query over ABCI and returns the raw protobuf value.
func (c *Client) abciQuery(ctx context.Context, path string, data []byte) ([]byte, error) {
	var r struct {
		Result struct {
			Response struct {
				Code  int    `json:"code"`
				Log   string `json:"log"`
				Value string `json:"value"`
			} `json:"response"`
		} `json:"result"`
		Error *struct {
			Message string `json:"message"`
			Data    string `json:"data"`
		} `json:"error"`
	}
	err := c.rpcCall(ctx, "abci_query", map[string]any{"path": path, "data": hex.EncodeToString(data), "prove": false}, &r)
	if err != nil {
		return nil, err
	}
	if r.Error != nil {
		return nil, fmt.Errorf("%s %s", r.Error.Message, r.Error.Data)
	}
	if r.Result.Response.Code != 0 {
		return nil, errors.New(Humanize(r.Result.Response.Log))
	}
	return base64.StdEncoding.DecodeString(r.Result.Response.Value)
}

// --- minimal protobuf helpers (avoid pulling in the SDK) ---

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func readVarint(b []byte) (uint64, int) {
	var v uint64
	for i := 0; i < len(b) && i < 10; i++ {
		v |= uint64(b[i]&0x7f) << (7 * i)
		if b[i] < 0x80 {
			return v, i + 1
		}
	}
	return 0, 0
}

// protoFields walks a message and calls fn for each field. Varint fields get
// the value in v; length-delimited fields get the bytes in data.
func protoFields(b []byte, fn func(num int, v uint64, data []byte)) {
	for len(b) > 0 {
		tag, n := readVarint(b)
		if n == 0 {
			return
		}
		b = b[n:]
		num, wt := int(tag>>3), tag&7
		switch wt {
		case 0:
			v, n := readVarint(b)
			if n == 0 {
				return
			}
			fn(num, v, nil)
			b = b[n:]
		case 2:
			l, n := readVarint(b)
			if n == 0 || int(l) > len(b)-n {
				return
			}
			fn(num, 0, b[n:n+int(l)])
			b = b[n+int(l):]
		case 1:
			if len(b) < 8 {
				return
			}
			b = b[8:]
		case 5:
			if len(b) < 4 {
				return
			}
			b = b[4:]
		default:
			return
		}
	}
}

// simulateTxBytes runs cosmos.tx.v1beta1.Service/Simulate and returns gas used.
func (c *Client) simulateTxBytes(ctx context.Context, txBytes []byte) (uint64, error) {
	// SimulateRequest { bytes tx_bytes = 2; }
	req := appendVarint([]byte{0x12}, uint64(len(txBytes)))
	req = append(req, txBytes...)
	val, err := c.abciQuery(ctx, "/cosmos.tx.v1beta1.Service/Simulate", req)
	if err != nil {
		return 0, err
	}
	// SimulateResponse { GasInfo gas_info = 1 { uint64 gas_wanted = 1; uint64 gas_used = 2; } }
	var used uint64
	protoFields(val, func(num int, _ uint64, data []byte) {
		if num == 1 {
			protoFields(data, func(n int, v uint64, _ []byte) {
				if n == 2 {
					used = v
				}
			})
		}
	})
	return used, nil
}
