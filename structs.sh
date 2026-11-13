#!/bin/bash
#
# structs.sh — a player-first client for Structs, built on structsd.
#
# Run with no arguments for the interactive menu, or use subcommands:
#
#   structs.sh wallet [player-id|address]        unified balance + delegations
#   structs.sh send <to> <amount> [--from SRC]   spend from the whole account
#   structs.sh delegate <validator> <amount>     infuse a reactor
#   structs.sh undelegate <validator> <amount>   defuse a reactor
#   structs.sh redelegate <from> <to> <amount>   migrate between reactors
#   structs.sh cancel-defuse <#> [amount]        put defusing alpha back
#   structs.sh consolidate [vault|primary|addr]  gather funds into one address
#   structs.sh guild                             guild administration menu
#
# Run `structs.sh help` for details.

SX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=structs-lib.sh
source "$SX_SCRIPT_DIR/structs-lib.sh"
# shellcheck source=structs-wallet.sh
source "$SX_SCRIPT_DIR/structs-wallet.sh"

sx_usage() {
    cat <<EOF
structs.sh $SX_VERSION — a player-first Structs client

USAGE
  structs.sh [options] [command] [args]

  With no command, opens the interactive menu.

WALLET
  wallet [player|address]            Show the whole player account: vault +
                                     every registered address, combined.
                                     Alias: balance. Pass a player id to look
                                     up anyone (view only).
  send <to> <amount> [--from SRC]    Send from the player account. Sources are
                                     picked automatically (vault first); a send
                                     that needs several sources becomes one
                                     atomic multi-message transaction.
                                     <to> is any structs1… address (player or
                                     not), a player id (their vault) or a
                                     guild id (the guild vault).
  delegate <validator> <amount>      Infuse alpha into a reactor from wherever
                                     it sits in the account.  Alias: infuse
  undelegate <validator> <amount>    Defuse, from whichever addresses hold the
                                     delegation.  Alias: defuse
  redelegate <from> <to> <amount>    Move a delegation between reactors.
                                     Alias: migrate
  cancel-defuse <#> [amount]         Cancel an in-progress defusion (# from
                                     the wallet view's DEFUSING list).
  consolidate [vault|primary|ADDR] [alpha|all|DENOM]
                                     Move all funds into one address
                                     (default: primary, alpha only).
  delegations [player]               Only the delegation section.

  <amount>    2.5alpha | 2500000ualpha | 10guild.0-3 | 500uguild.0-3 | all
              (a number needs a unit: 100 alone is refused)
  <validator> reactor id (3-12), owning player id (1-186), guild id (0-3,
              its primary reactor), moniker, or structsvaloper1... address
  SRC         vault | primary | one of your registered addresses

GUILD
  guild                              Guild administration menu (guild.sh)

OPTIONS
  -y, --yes             Do not ask for confirmation
  -n, --dry-run         Plan and simulate every message, but do not sign
  -k, --key NAME        Keyring key to sign with (default: saved config)
  -v, --verbose         Show per-address breakdown for every delegation
      --json            (wallet) print the raw account JSON
  -h, --help            This help

ENVIRONMENT
  STRUCTSD_FLAGS     extra structsd flags, e.g. "--node tcp://host:26657"
  STRUCTSD_TX_FLAGS  extra tx-only flags, e.g. "--fees 0ualpha"
  STRUCTS_CHAIN_ID   chain id (default: detected from the node)
EOF
}

sx_main_menu() {
    local opt
    while :; do
        clear 2>/dev/null
        echo -e "${BLUE}======================================================${NC}"
        echo -e "${BLUE}                     STRUCTS.SH                      ${NC}"
        echo -e "${BLUE}======================================================${NC}"
        echo -e " Key: ${GREEN}${STRUCTS_ACCOUNT:-none}${NC}  Player: ${GREEN}${SX_PLAYER_ID:-not registered}${NC}  Chain: $(sx_chain_id)"
        echo ""
        echo -e "   ${GREEN}1.${NC} Wallet (balances, send, delegations)"
        echo -e "   ${GREEN}2.${NC} Look up a player"
        echo -e "   ${GREEN}3.${NC} Guild administration"
        echo -e "   ${GREEN}4.${NC} Switch key"
        echo -e "   ${GREEN}0.${NC} Exit"
        echo ""
        read -r -p "Select an option: " opt
        case "$opt" in
            1) sx_wallet_menu "$SX_PLAYER_ID" ;;
            2) local who; read -r -p "Player id or address: " who; [ -n "$who" ] && sx_wallet_menu "$who" ;;
            3) exec bash "$SX_SCRIPT_DIR/guild.sh" ;;
            4) STRUCTS_ACCOUNT=""; sx_select_account && sx_load_account ;;
            0) exit 0 ;;
        esac
    done
}

main() {
    sx_require

    # Global options (may appear anywhere)
    local args=() json=0 from_sel=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) SX_ASSUME_YES=1 ;;
            -n|--dry-run) SX_DRY_RUN=1 ;;
            -k|--key) STRUCTS_ACCOUNT="$2"; shift ;;
            -v|--verbose) SX_VERBOSE=1 ;;
            --json) json=1 ;;
            --from) from_sel="$2"; shift ;;
            -h|--help) sx_usage; exit 0 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    set -- "${args[@]+"${args[@]}"}"

    local cmd="${1:-}"
    [ $# -gt 0 ] && shift

    case "$cmd" in
        help) sx_usage; exit 0 ;;
        guild) exec bash "$SX_SCRIPT_DIR/guild.sh" ;;
    esac

    # Viewing another player needs no key; everything else does.
    local need_key=1
    if { [ "$cmd" = "wallet" ] || [ "$cmd" = "balance" ] || [ "$cmd" = "delegations" ]; } && [ -n "${1:-}" ]; then
        need_key=0
    fi
    if [ $need_key -eq 1 ]; then
        sx_load_account || exit 1
    else
        sx_load_account >/dev/null 2>&1 || true
    fi

    case "$cmd" in
        "")
            [ -t 0 ] || { sx_usage; exit 1; }
            sx_main_menu ;;
        wallet|balance|delegations)
            local who="${1:-$SX_PLAYER_ID}"
            [ -z "$who" ] && sx_die "your key is not registered to a player; pass a player id"
            sx_wallet_load "$who" || exit 1
            if [ $json -eq 1 ]; then echo "$SX_WALLET" | jq .; exit 0; fi
            if [ "$cmd" = "delegations" ]; then sx_wallet_show_delegations; else sx_wallet_show; fi ;;
        send)
            [ $# -lt 2 ] && sx_die "usage: send <to> <amount> [--from vault|primary|ADDR]"
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_send "$1" "$2" "$from_sel" ;;
        delegate|infuse)
            [ $# -lt 2 ] && sx_die "usage: delegate <validator> <amount> [--from SRC]"
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_delegate "$1" "$2" "$from_sel" ;;
        undelegate|defuse)
            [ $# -lt 2 ] && sx_die "usage: undelegate <validator> <amount|all> [--from SRC]"
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_undelegate "$1" "$2" "$from_sel" ;;
        redelegate|migrate)
            [ $# -lt 3 ] && sx_die "usage: redelegate <from-validator> <to-validator> <amount|all>"
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_redelegate "$1" "$2" "$3" ;;
        cancel-defuse|cancel-unbond)
            [ $# -lt 1 ] && sx_die "usage: cancel-defuse <#> [amount]"
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_cancel_defuse "$1" "${2:-}" ;;
        consolidate)
            sx_wallet_load "$SX_PLAYER_ID" || exit 1
            sx_wallet_consolidate "${1:-primary}" "${2:-ualpha}" ;;
        *)
            sx_err "unknown command '$cmd'"; echo "" >&2; sx_usage >&2; exit 1 ;;
    esac
}

main "$@"
