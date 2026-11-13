package chain

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var (
	reAddress  = regexp.MustCompile(`^structs1[02-9ac-hj-np-z]{38,}$`)
	reValoper  = regexp.MustCompile(`^structsvaloper1[02-9ac-hj-np-z]{38,}$`)
	rePlayer   = regexp.MustCompile(`^1-[0-9]+$`)
	reGuild    = regexp.MustCompile(`^0-[0-9]+$`)
	reReactor  = regexp.MustCompile(`^3-[0-9]+$`)
	reProvider = regexp.MustCompile(`^10-[0-9]+$`)
)

func IsAddress(s string) bool    { return reAddress.MatchString(s) }
func IsValoper(s string) bool    { return reValoper.MatchString(s) }
func IsPlayerID(s string) bool   { return rePlayer.MatchString(s) }
func IsGuildID(s string) bool    { return reGuild.MatchString(s) }
func IsReactorID(s string) bool  { return reReactor.MatchString(s) }
func IsProviderID(s string) bool { return reProvider.MatchString(s) }

// ---------------------------------------------------------------- player

type Player struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	GuildID        string `json:"guildId"`
	GuildRank      string `json:"guildRank"`
	SubstationID   string `json:"substationId"`
	PlanetID       string `json:"planetId"`
	FleetID        string `json:"fleetId"`
	PrimaryAddress string `json:"primaryAddress"`
	Creator        string `json:"creator"`
}

type PlayerDetail struct {
	Player         Player            `json:"Player"`
	GridAttributes map[string]string `json:"gridAttributes"`
}

func (c *Client) Player(ctx context.Context, id string) (PlayerDetail, error) {
	var p PlayerDetail
	err := c.Query(ctx, &p, "structs", "player", id)
	return p, err
}

type AddressRecord struct {
	Address     string `json:"address"`
	PlayerID    string `json:"playerId"`
	Permissions string `json:"permissions"`
}

// PlayerOfAddress returns "" when the address is not registered.
func (c *Client) PlayerOfAddress(ctx context.Context, addr string) (string, error) {
	var r AddressRecord
	if err := c.Query(ctx, &r, "structs", "address", addr); err != nil {
		return "", err
	}
	if r.PlayerID == "1-0" {
		return "", nil
	}
	return r.PlayerID, nil
}

func (c *Client) PlayerAddresses(ctx context.Context, playerID string) ([]AddressRecord, error) {
	return QueryAll[AddressRecord](ctx, c, "address", "structs", "address-all-by-player", playerID)
}

func (c *Client) Players(ctx context.Context) ([]Player, error) {
	return QueryAll[Player](ctx, c, "Player", "structs", "player-all")
}

// Vault returns the vault address of a player or guild.
func (c *Client) Vault(ctx context.Context, ownerID string) (string, error) {
	var r struct {
		Address string `json:"address"`
	}
	err := c.Query(ctx, &r, "structs", "vault", ownerID)
	return r.Address, err
}

// ---------------------------------------------------------------- bank

func (c *Client) Balances(ctx context.Context, addr string) ([]Coin, error) {
	var r struct {
		Balances []Coin `json:"balances"`
	}
	err := c.Query(ctx, &r, "bank", "balances", addr)
	return r.Balances, err
}

func (c *Client) Balance(ctx context.Context, addr, denom string) (Int, error) {
	var r struct {
		Balance Coin `json:"balance"`
	}
	err := c.Query(ctx, &r, "bank", "balance", addr, denom)
	return r.Balance.Amount, err
}

func (c *Client) Supply(ctx context.Context, denom string) (Int, error) {
	var r struct {
		Amount Coin `json:"amount"`
	}
	err := c.Query(ctx, &r, "bank", "total-supply-of", denom)
	return r.Amount.Amount, err
}

// ---------------------------------------------------------------- staking

type Delegation struct {
	Validator string
	Amount    Int
}

func (c *Client) Delegations(ctx context.Context, addr string) ([]Delegation, error) {
	var r struct {
		Responses []struct {
			Delegation struct {
				Validator string `json:"validator_address"`
			} `json:"delegation"`
			Balance Coin `json:"balance"`
		} `json:"delegation_responses"`
	}
	if err := c.Query(ctx, &r, "staking", "delegations", addr); err != nil {
		return nil, err
	}
	var out []Delegation
	for _, d := range r.Responses {
		if !d.Balance.Amount.IsZero() {
			out = append(out, Delegation{Validator: d.Delegation.Validator, Amount: d.Balance.Amount})
		}
	}
	return out, nil
}

type Unbonding struct {
	Validator      string
	CreationHeight string
	Completion     time.Time
	Balance        Int
}

func (c *Client) Unbondings(ctx context.Context, addr string) ([]Unbonding, error) {
	var r struct {
		Responses []struct {
			Validator string `json:"validator_address"`
			Entries   []struct {
				CreationHeight string    `json:"creation_height"`
				CompletionTime time.Time `json:"completion_time"`
				Balance        Int       `json:"balance"`
			} `json:"entries"`
		} `json:"unbonding_responses"`
	}
	if err := c.Query(ctx, &r, "staking", "unbonding-delegations", addr); err != nil {
		return nil, err
	}
	var out []Unbonding
	for _, u := range r.Responses {
		for _, e := range u.Entries {
			out = append(out, Unbonding{Validator: u.Validator, CreationHeight: e.CreationHeight, Completion: e.CompletionTime, Balance: e.Balance})
		}
	}
	return out, nil
}

// Rewards returns unclaimed staking rewards (whole base units).
func (c *Client) Rewards(ctx context.Context, addr string) (Int, error) {
	var r struct {
		Total json.RawMessage `json:"total"`
	}
	if err := c.Query(ctx, &r, "distribution", "rewards", addr); err != nil {
		return NewInt(0), err
	}
	// Either ["74.1ualpha"] or [{"denom":..,"amount":..}]
	var strs []string
	if json.Unmarshal(r.Total, &strs) == nil {
		for _, s := range strs {
			if strings.HasSuffix(s, Alpha) {
				return ParseInt(strings.TrimSuffix(s, Alpha))
			}
		}
		return NewInt(0), nil
	}
	var coins []struct {
		Denom  string `json:"denom"`
		Amount string `json:"amount"`
	}
	_ = json.Unmarshal(r.Total, &coins)
	for _, cn := range coins {
		if cn.Denom == Alpha {
			return ParseInt(cn.Amount)
		}
	}
	return NewInt(0), nil
}

type Validator struct {
	Operator string
	Moniker  string
	Status   string
	Jailed   bool
	Tokens   Int
	// from the structs reactor index
	ReactorID string
	Owner     string
	GuildID   string
}

func (v Validator) Bonded() bool { return v.Status == "BOND_STATUS_BONDED" }

func (v Validator) Label() string {
	s := v.Moniker
	if s == "" {
		s = v.Operator[:20] + "…"
	}
	if v.ReactorID != "" {
		s += " (" + v.ReactorID + ")"
	}
	if v.Jailed {
		s += " [JAILED]"
	} else if v.Status != "" && !v.Bonded() {
		s += " [" + strings.TrimPrefix(v.Status, "BOND_STATUS_") + "]"
	}
	return s
}

// Validators merges staking validators with structs reactors.
func (c *Client) Validators(ctx context.Context) (map[string]*Validator, error) {
	type sv struct {
		Operator    string `json:"operator_address"`
		Description struct {
			Moniker string `json:"moniker"`
		} `json:"description"`
		Status string `json:"status"`
		Jailed bool   `json:"jailed"`
		Tokens Int    `json:"tokens"`
	}
	type rv struct {
		ID        string `json:"id"`
		Validator string `json:"validator"`
		Owner     string `json:"owner"`
		GuildID   string `json:"guildId"`
	}
	vals, err := QueryAll[sv](ctx, c, "validators", "staking", "validators")
	if err != nil {
		return nil, err
	}
	reactors, err := QueryAll[rv](ctx, c, "Reactor", "structs", "reactor-all")
	if err != nil {
		return nil, err
	}
	out := map[string]*Validator{}
	for _, v := range vals {
		out[v.Operator] = &Validator{Operator: v.Operator, Moniker: v.Description.Moniker, Status: v.Status, Jailed: v.Jailed, Tokens: v.Tokens}
	}
	for _, r := range reactors {
		v, ok := out[r.Validator]
		if !ok {
			v = &Validator{Operator: r.Validator}
			out[r.Validator] = v
		}
		v.ReactorID, v.Owner, v.GuildID = r.ID, r.Owner, r.GuildID
	}
	return out, nil
}

type StakeShare struct {
	ReactorID                  string `json:"reactorId"`
	CapActive                  bool   `json:"capActive"`
	ExternalDepositHeadroom    Int    `json:"externalDepositHeadroom"`
	BondedRedelegationHeadroom Int    `json:"bondedRedelegationHeadroom"`
	ValidatorTokens            Int    `json:"validatorTokens"`
}

func (c *Client) StakeShare(ctx context.Context, reactorID string) (StakeShare, error) {
	var s StakeShare
	err := c.Query(ctx, &s, "structs", "reactor-stake-share", reactorID)
	return s, err
}

func (c *Client) UnbondingTime(ctx context.Context) string {
	var r struct {
		Params struct {
			UnbondingTime string `json:"unbonding_time"`
		} `json:"params"`
	}
	_ = c.Query(ctx, &r, "staking", "params")
	return r.Params.UnbondingTime
}

// ---------------------------------------------------------------- guild

type Guild struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Endpoint          string `json:"endpoint"`
	Owner             string `json:"owner"`
	PrimaryReactorID  string `json:"primaryReactorId"`
	EntrySubstationID string `json:"entrySubstationId"`
	EntryRank         string `json:"entryRank"`
	JoinInfusionMin   string `json:"joinInfusionMinimum"`
	BypassByRequest   string `json:"joinInfusionMinimumBypassByRequest"`
	BypassByInvite    string `json:"joinInfusionMinimumBypassByInvite"`
	BankConvertInFee  string `json:"bankConvertInFee"`
	BankConvertOutFee string `json:"bankConvertOutFee"`
}

func (c *Client) Guild(ctx context.Context, id string) (Guild, error) {
	var r struct {
		Guild Guild `json:"Guild"`
	}
	err := c.Query(ctx, &r, "structs", "guild", id)
	return r.Guild, err
}

func (c *Client) GuildBankCollateral(ctx context.Context, guildID string) (string, error) {
	var r struct {
		A []struct {
			Address string `json:"address"`
		} `json:"internalAddressAssociation"`
	}
	if err := c.Query(ctx, &r, "structs", "guild-bank-collateral-address", guildID); err != nil || len(r.A) == 0 {
		return "", err
	}
	return r.A[0].Address, nil
}

type Application struct {
	GuildID            string `json:"guildId"`
	PlayerID           string `json:"playerId"`
	JoinType           string `json:"joinType"`
	RegistrationStatus string `json:"registrationStatus"`
	Proposer           string `json:"proposer"`
	SubstationID       string `json:"substationId"`
}

func (a Application) Type() string {
	if a.JoinType == "" {
		return "invite"
	}
	return a.JoinType
}

func (a Application) Status() string {
	if a.RegistrationStatus == "" {
		return "proposed"
	}
	return a.RegistrationStatus
}

func (c *Client) Applications(ctx context.Context) ([]Application, error) {
	return QueryAll[Application](ctx, c, "GuildMembershipApplication", "structs", "guild-membership-application-all")
}

type Provider struct {
	ID              string `json:"id"`
	SubstationID    string `json:"substationId"`
	Rate            Coin   `json:"rate"`
	AccessPolicy    string `json:"accessPolicy"`
	CapacityMinimum string `json:"capacityMinimum"`
	CapacityMaximum string `json:"capacityMaximum"`
	DurationMinimum string `json:"durationMinimum"`
	DurationMaximum string `json:"durationMaximum"`
	Owner           string `json:"owner"`
}

func (p Provider) Policy() string {
	if p.AccessPolicy == "" {
		return "open-market"
	}
	return p.AccessPolicy
}

func (c *Client) Providers(ctx context.Context) ([]Provider, error) {
	return QueryAll[Provider](ctx, c, "Provider", "structs", "provider-all")
}

type Substation struct {
	ID    string            `json:"id"`
	Owner string            `json:"owner"`
	Name  string            `json:"name"`
	Grid  map[string]string `json:"-"`
}

func (c *Client) Substation(ctx context.Context, id string) (Substation, error) {
	var r struct {
		Substation Substation        `json:"Substation"`
		Grid       map[string]string `json:"gridAttributes"`
	}
	err := c.Query(ctx, &r, "structs", "substation", id)
	r.Substation.Grid = r.Grid
	return r.Substation, err
}

// AccountSequence returns the signer's sequence for offline simulation.
func (c *Client) AccountSequence(ctx context.Context, addr string) (string, error) {
	var r struct {
		Account struct {
			Value struct {
				Sequence string `json:"sequence"`
			} `json:"value"`
			Sequence string `json:"sequence"`
		} `json:"account"`
	}
	if err := c.Query(ctx, &r, "auth", "account", addr); err != nil {
		return "", err
	}
	return firstNonEmpty(r.Account.Value.Sequence, r.Account.Sequence, "0"), nil
}

// AccountExists reports whether the address has ever been used on chain.
func (c *Client) AccountExists(ctx context.Context, addr string) bool {
	var r map[string]any
	return c.Query(ctx, &r, "auth", "account", addr) == nil
}
