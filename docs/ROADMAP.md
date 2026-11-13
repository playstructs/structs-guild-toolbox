# structs.sh — functionality review and roadmap

Reviewed against `structsd master-fe8d98987cd5` on `structstestnet-111` (Nov 2026).

## Direction

The repo started as a guild admin menu (`guild.sh`). It is now `structs.sh`: a
player-first client with guild admin as one section. The goal is **not** a
1:1 `structsd` wrapper. The client should:

- **Hide the plumbing.** A player is one account. Which address holds the funds
  (vault, primary, other registered keys) is a detail the client handles.
- **Resolve names.** Accept player ids, reactor ids, guild ids and monikers
  wherever `structsd` wants a bech32 address.
- **Plan, then show, then do.** Every write shows a plan first, simulates every
  message, and bundles multi-part actions into one atomic transaction.
- **Be scriptable.** Every interactive action also works as a subcommand
  (`-y`, `--dry-run`, `--json`), so bots and automation can use it.

## What exists today

| Area | Entry | Status |
|---|---|---|
| **Interactive client** | `structs` (Go, Bubble Tea) | Wallet, stake, guild and activity panels. `/` commands with autocomplete. Plan → simulate → confirm cards. Animated reactor. |
| **Unified wallet** | `/send /consolidate /delegate /undelegate /redelegate /cancel-defuse` (also in `structs.sh`) | Working. Every flow simulates on testnet. |
| **Guild bank** | `/convert /redeem /mint` | Working. Convert/redeem top up the player vault inside the same transaction. |
| **Guild membership** | `/invite /approve /deny /kick /members` (TUI); `guild.sh` → 4 | Rewritten for the current CLI (`request-deny`, `invite-revoke [guild] [player]`, kick, pending list, member list). |
| Energy grid | `guild.sh` → 2; `/withdraw` | Rewritten: provider list, create (player- or guild-owned), view, withdraw, access policy, delete. |
| Central bank | `guild.sh` → 3 | Rewritten: guild-vault treasury mint, convert/redeem with slippage guards, account-wide transfers. |
| Permissions | `guild.sh` → 6 | Updated to 25 bits (`PermGuildUGCUpdate`); `PermGuildAll` corrected to 17169406. Not in the TUI yet. |
| Guild bootstrap | `create_guild.sh`, `guild-setup.sh`, chain monitor | Fixed: `guild-create [reactor] [endpoint] [substation]`, defaulting to your own reactor. |
| Guild configuration | `guild.sh` → 5 | Still a stub. |

### Architecture of `structs`

- `internal/chain`: runs `structsd` for queries and keys, so it honours the user's keyring, home and node. Queries run concurrently.
- `internal/chain` (tx engine): merges messages into one tx, simulates the **whole** tx over CometBFT RPC (`abci_query /cosmos.tx.v1beta1.Service/Simulate`), then signs once with `structsd tx sign` and broadcasts. Dependent messages are therefore checked together, unlike `--gas auto` on each message.
- `internal/wallet`: account loading, source planning, and action builders. `internal/guild`: guild state and admin plans.
- `internal/tui`: the Bubble Tea app. `structs snapshot` renders frames headlessly for docs and tests, and is always dry-run.
- `internal/art`: the reactor sprite, downsampled from the illustration, drawn with half-blocks and animated (breathing tube, rising bubbles, pulsing crystal). `--ascii` falls back to plain characters.

### Unified wallet: how it works

A player account is the **Player Vault** (`query structs vault <player>`) plus
**every registered address** (`query structs address-all-by-player <player>`).
Any registered key can move funds out of any of them with `player-send`, or
stake them with `reactor-infuse`, `reactor-defuse`, `reactor-begin-migration`
or `reactor-cancel-defusion` plus `--delegator-address`. These messages are
gasless (fee `0ualpha`).

- **View:** combined available, delegated, defusing and reward totals. Also a
  per-source breakdown, and delegations grouped by validator with the source
  addresses underneath.
- **Send / delegate:** sources are filled greedily (vault first, then the
  primary, then the other addresses). If more than one source is needed, each
  message is simulated on its own (`--generate-only --gas auto`). The messages
  are then merged into **one** transaction, signed once and broadcast, so all
  parts succeed or none do.
- **Undelegate / redelegate:** draws from the largest delegation to the
  validator first, whichever address holds it.
- **Stake cap:** warns when `reactor-stake-share` shows the target reactor
  can't take the amount.
- **Lookup:** `structs.sh wallet <player-id>` gives a read-only view of anyone's
  account, which is useful for answering support questions.

Checked on testnet (simulation only; nothing was broadcast):

- A split send for 1-28, 0.5 from the vault and 0.3 from the primary.
- Delegate-all across two sources.
- Consolidate from the vault into the primary.
- Infuse from the vault.
- Defuse and migrate a delegation held by the primary.
- A secondary registered key spending from the vault.
- Overspend and over-undelegate guards.

## Fixed against the current chain (Nov 2026)

All items from the first review are fixed: `guild-create` signature, redeem/convert slippage guards, mint from the guild treasury, membership command renames and query typo, the energy-grid substation bug, the removed `provider-grant/revoke-guild`, the undefined `view_provider_details`, and the 25th permission bit. Every rewritten call was checked by simulation as the owner of guild 0-3. The only failures were real chain state, e.g. "guild 0-3 is not currently allowing invite" and an empty treasury.

## Chain-side observations

- **`address-all-by-player` filters within each page of the global address
  index.** The first page is usually empty even when the player has addresses.
  You have to walk every `next_key` (about 15 pages of 1000 on testnet).
  `structs-lib.sh:sx_q_all` does this. A player-prefixed index on chain would
  make it one call.
- **No reverse lookup for vaults.** `query structs address <vault>` returns
  nothing, so you can't go from a vault address to its owner. A `vault-by-address`
  query (or registering vaults in the address index) would let tools show
  "this is player 1-186's vault".
- **Staking rewards on vault-held delegations.** Rewards accrue to the
  delegator address, and the vault has no key to run
  `distribution withdraw-rewards`. Confirm whether the module auto-claims or
  needs a `player-withdraw-rewards`-style message. The wallet shows unclaimed
  rewards today but has no claim action yet.
- `structsd tx --dry-run` refuses `--from` addresses whose key can't sign.
  Simulation through `--generate-only --gas auto` works with watch-only keys,
  and so does the REST `/cosmos/tx/v1beta1/simulate` endpoint.

## Roadmap

### Not yet verified
- **Signing and broadcasting from `structs`.** Everything up to signing (generate, merge, whole-tx simulation) is tested on testnet. Signing and broadcasting a real transaction needs a player key, which this machine doesn't have.
- **The `file` keyring backend.** `structs` asks for the passphrase and pipes it to `structsd tx sign`; untested.

### P0 — finish the account-abstraction story
1. **Claim rewards** across all sources: `distribution withdraw-all-rewards` for
   local keys, plus whatever the vault needs (see above).
2. **Guild vaults** for guild owners/admins: show the guild vault next to the
   player account, `vault-send` between player and guild vaults, and make the
   central bank use the guild vault.
3. **Address management**: `address-register` (link another key), `address-revoke`,
   `player-update-primary-address`, and per-address permissions shown in the
   wallet.
4. **History**: `tx_search` across every source address, merged into one
   account timeline (sends, infusions, defusions, game actions).
5. **`whois <anything>`**: an address, vault, valoper, player, guild, reactor
   or substation, resolved to what it is and who owns it.

### P1 — player client
- **Guild bank for members**: `guild-bank-convert`, `convert-token` and `redeem`,
  with the slippage guard computed from the live collateral ratio. Also
  `guild-rank-purchase` and `join-by-rank-purchase`.
- **Guild discovery & joining**: list guilds with their join rules; invite and
  request inbox (approve/deny/revoke).
- **Energy market**: browse open providers, `agreement-open`, increase/decrease,
  close; substation connect/disconnect.
- **Player status**: profile (name/pfp), planet, fleet, structs and their
  state. Build, mine and refine flows that run the `*-compute` proof-of-work
  steps.

### P2 — guild admin repairs and gaps
- Bring permissions and guild configuration into the TUI (bash only today).
- Guild configuration: name, pfp, endpoint, entry rank, entry substation, join
  minimums, bank convert-in/out fees, rank purchase, primary reactor, owner.
- Membership: list pending applications (`guild-membership-application-all`
  filtered by guild), kick, rank management in bulk.
- Providers: update/delete, list agreements, earnings, withdraw to the guild
  vault.
- Reactor operations for validator guilds: stake share, diversity, restart,
  commission.

### P3 — platform
- Move the guild modules onto `structs-lib.sh` (shared tx engine, amount
  parsing, name resolution) and drop the per-module `structsd` boilerplate.
- `--json` output on every read command, for bots, Discord, dashboards.
- Speed: the wallet does about 4 `structsd` processes per address. When a REST
  endpoint is available, batch through `curl` instead (about 10× faster).
- Tests: `bats` against recorded JSON fixtures, and a CI job that runs the
  `--dry-run` scenarios against testnet.
- Config: move `~/.structs-guild-admin` to `~/.structs-toolbox`, with migration.
- Repo name: `structs-toolbox` (or `structs.sh`) to match the new scope.
