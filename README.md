# structs-guild-toolbox

**`structs`** is an interactive terminal client for [Structs](https://playstructs.com). It runs on top of your existing `structsd` keyring and node. It shows your whole player account as one wallet and turns every action into a simulated, confirm-first transaction.

```
◆ STRUCTS ▸  1 Wallet  2 Stake  3 Guild  4 Activity            ● structstestnet-111 #3,574,558
──────────────────────────────────────────────────────────────────────────────────────────────
  [animated reactor]     PLAYER 1-28 · guild 0-3
                           2,449.00117 alpha
                           ████████████████████████████████████████
                           ■ available        1.00117
                           ■ delegated          2,448
                         WHERE IT IS                       AVAILABLE      DELEGATED
                           ◆ Player Vault    structs1v22d…k9du6p      0.5              0
                           ● Primary wallet  structs1ffrj…y0tmj5  0.50117          2,448
╭────────────────────────────────────────────────────────────────────────────────────────────╮
│ › /send 1-186 0.8alpha                                                                     │
╰────────────────────────────────────────────────────────────────────────────────────────────╯
```

## Install

Requires Go 1.24+ and `structsd` on your `PATH`.

```bash
make build            # → bin/structs
./bin/structs         # your account (key from ~/.structs-guild-admin/config.json, or --key)
./bin/structs 1-186   # anyone's account, read only
./bin/structs reactor # just the reactor, animated
```

It reads `~/.structs/config/client.toml`, or `<--home>/config/client.toml`, the same file `structsd` uses:
- `keyring-backend` picks the keyring.
- `keyring-default-keyname` is the default signing key.
- `node` and `chain-id` pick the chain.

The signing key is chosen in this order: `--key`, then `keyring-default-keyname`, then the key you last picked with `/key`, then the only key in the keyring that belongs to a player. Override any setting with `--node`, `--home`, `--keyring-backend`, `--chain-id` and `--fees`, or with the `STRUCTSD_FLAGS` / `STRUCTSD_TX_FLAGS` environment variables. Add `--dry-run` to simulate everything without signing.

### Locked keyrings

Some keyrings need unlocking before `structs` can see your keys:

- **`file` keyring, or `os` on a Linux server with no desktop keyring.** The SDK's `os` backend falls back to an encrypted file keyring when it can't find one. `structs` notices the keyring is locked and asks for its passphrase. It keeps the passphrase in memory for the session and never writes it to disk. Type `/unlock` to enter it again.
- **macOS Keychain (`os`).** On the Mac itself, approve the Keychain dialog with "Always Allow". Over SSH the keychain is locked: run `security unlock-keychain ~/Library/Keychains/login.keychain-db`, then press ctrl+r.
- **Linux Secret Service or KWallet (`os`).** Unlock it in your desktop session, or switch to `keyring-backend = "file"` on a headless machine.

## One account, many addresses

A Structs player account is your **Player Vault** plus **every address registered to your player**, and any of your keys can spend from all of them. `structs` adds them up, shows where everything sits, and picks the sources for you.

Type `/` for the command menu. **Tab** completes, and **Enter** plans the action:

| Command | What it does |
|---|---|
| `/send <to> <amount> [from]` | Send from the whole account. `<to>` is any `structs1…` address, including non-player accounts such as exchanges or fresh wallets, a player id (their vault) or a guild id (its vault). The checksum is verified before anything is built. The card says whose address it is, and warns when an address has never been used on chain. |
| `/consolidate [vault\|primary\|addr]` | Move every balance into one address. |
| `/delegate <reactor> <amount>` | Infuse a reactor from wherever your alpha sits. |
| `/undelegate <reactor> <amount\|all>` | Defuse from whichever addresses hold the stake. |
| `/redelegate <from> <to> <amount>` | Move stake between reactors. |
| `/cancel-defuse <#>` | Put a defusion back into its reactor. |
| `/convert <alpha> [guild]` · `/redeem <tokens\|all> [guild]` | Guild bank, with the slippage guard computed from the live ratio. |
| `/invite` `/approve` `/deny` `/kick` `/members` `/mint` `/withdraw` | Guild admin. |
| `/wallet <player>` | Look anyone up. Typing a bare player id or address does the same. |

Reactors can be named by reactor id (`3-12`), owning player (`1-186`), guild (`0-3`, its primary reactor), moniker or valoper. Amounts need a unit: `2.5alpha`, `2500000ualpha`, `10guild.0-3` or `all`. A bare `100` is refused, because it could mean 100 alpha or 100 ualpha (0.0001 alpha).

**Every action is planned, simulated, then confirmed.** The card shows each source it will draw from, simulates the whole transaction against the chain, and only then offers **⏎ sign & broadcast**. Actions that need several sources become one atomic multi-message transaction. Some actions depend on an earlier step in the same transaction: guild banks only use your Player Vault, so `/convert` and `/redeem` first move any shortfall into the vault, then convert.

## Scripting: structs.sh

`structs.sh` is the bash version of the same wallet for scripts and servers (`jq` and `bc` required, bash 3.2+):

```bash
./structs.sh wallet 1-186
./structs.sh -y send 1-28 2.5alpha
./structs.sh --dry-run delegate 3-12 all
./structs.sh guild          # the menu-driven guild admin tool (guild.sh)
```

See [docs/ROADMAP.md](docs/ROADMAP.md) for what exists and what's planned.

## Structs
In the distant future the species of the galaxy are embroiled in a race for Alpha Matter, the rare and dangerous substance that fuels galactic civilization. Players take command of Structs, a race of sentient machines, and must forge alliances, conquer enemies and expand their influence to control Alpha Matter and the fate of the galaxy.

[Structs](https://playstructs.com) is a decentralized game in the Cosmos ecosystem, operated and governed by our community of players--ensuring Structs remains online as long as there are players to play it.


## Learn more

- [Structs](https://playstructs.com)
- [Project Wiki](https://watt.wiki)
- [@PlayStructs Twitter](https://twitter.com/playstructs)


## License

Copyright 2021 [Slow Ninja Inc](https://slow.ninja).

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.