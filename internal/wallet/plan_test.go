package wallet

import (
	"testing"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
)

func acct() *Account {
	i := chain.MustInt
	return &Account{
		PlayerID: "1-28", Vault: "V", Primary: "P",
		Sources: []*Source{
			{Address: "V", Kind: KindVault, Balances: map[string]chain.Int{"ualpha": i("500000")}},
			{Address: "P", Kind: KindPrimary, Balances: map[string]chain.Int{"ualpha": i("501170"), "uguild.0-3": i("10")},
				Delegations: []chain.Delegation{{Validator: "val1", Amount: i("2448000000")}}},
			{Address: "X", Kind: KindAddress, Balances: map[string]chain.Int{"ualpha": i("7")},
				Delegations: []chain.Delegation{{Validator: "val1", Amount: i("5")}}},
		},
	}
}

func amt(s string) chain.Amount { a, _ := chain.ParseAmount(s, chain.Alpha); return a }

func TestPlanLiquidSplitsVaultFirst(t *testing.T) {
	d, err := acct().PlanLiquid("ualpha", amt("0.8alpha"), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(d) != 2 || d[0].Address != "V" || d[0].Amount.String() != "500000" || d[1].Address != "P" || d[1].Amount.String() != "300000" {
		t.Fatalf("bad plan %+v", d)
	}
}

func TestPlanLiquidExcludesRecipientAndAll(t *testing.T) {
	d, err := acct().PlanLiquid("ualpha", amt("all"), "", "P")
	if err != nil {
		t.Fatal(err)
	}
	if sumDraws(d).String() != "500007" {
		t.Fatalf("got %s", sumDraws(d))
	}
}

func TestPlanLiquidInsufficient(t *testing.T) {
	if _, err := acct().PlanLiquid("ualpha", amt("5alpha"), "", ""); err == nil {
		t.Fatal("expected error")
	}
	if _, err := acct().PlanLiquid("ualpha", amt("0.6alpha"), "V", ""); err == nil {
		t.Fatal("expected error when pinned to vault")
	}
}

func TestPlanDelegationLargestFirst(t *testing.T) {
	d, err := acct().PlanDelegation("val1", amt("2448000003"), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(d) != 2 || d[0].Address != "P" || d[1].Address != "X" || d[1].Amount.String() != "3" {
		t.Fatalf("bad plan %+v", d)
	}
}

func TestTopUpVault(t *testing.T) {
	b := &Builder{A: acct()}
	p := &Plan{}
	if err := b.topUpVault(p, "uguild.0-3", chain.MustInt("4")); err != nil {
		t.Fatal(err)
	}
	if len(p.Msgs) != 1 || p.Msgs[0][2] != "P" || p.Msgs[0][3] != "V" || p.Msgs[0][4] != "4uguild.0-3" {
		t.Fatalf("bad top-up %+v", p.Msgs)
	}
}

func TestQuotes(t *testing.T) {
	bs := &BankState{Collateral: chain.MustInt("1000000"), Supply: chain.MustInt("2000000"), FeeIn: rat("0.01"), FeeOut: rat("0")}
	tok, fee := bs.QuoteConvert(chain.MustInt("1000"))
	if fee.String() != "10" || tok.String() != "1980" {
		t.Fatalf("convert: %s fee %s", tok, fee)
	}
	alpha, _ := bs.QuoteRedeem(chain.MustInt("1980"))
	if alpha.String() != "990" {
		t.Fatalf("redeem: %s", alpha)
	}
	if withSlippage(chain.MustInt("1000")).String() != "990" {
		t.Fatal("slippage")
	}
}
