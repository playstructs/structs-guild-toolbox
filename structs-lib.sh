#!/bin/bash
#
# structs-lib.sh — shared, non-interactive core for structs.sh
#
# Everything here is safe to source from other scripts (guild.sh included):
# functions are prefixed `sx_` so they never collide with the older guild
# modules (print_header, load_config, ...). Written for bash 3.2 (macOS
# default): no associative arrays, no mapfile, no ${var,,}.
#
# Environment overrides:
#   STRUCTSD           structsd binary (default: structsd)
#   STRUCTSD_FLAGS     extra flags for every structsd call, e.g.
#                      "--node tcp://host:26657 --home ~/.structs --keyring-backend test"
#   STRUCTSD_TX_FLAGS  extra flags for transactions only, e.g. "--fees 0ualpha"
#   STRUCTS_ACCOUNT    keyring key name to sign with (overrides saved config)
#   STRUCTS_CHAIN_ID   chain id (default: detected from the node)
#   SX_GAS_ADJUSTMENT  gas adjustment for simulation (default 1.5)

SX_VERSION="2.0.0"

STRUCTSD="${STRUCTSD:-structsd}"
STRUCTSD_FLAGS="${STRUCTSD_FLAGS:-}"
STRUCTSD_TX_FLAGS="${STRUCTSD_TX_FLAGS:-}"
SX_GAS_ADJUSTMENT="${SX_GAS_ADJUSTMENT:-1.5}"

# Shared with guild.sh so both tools use the same saved account
CONFIG_DIR="${CONFIG_DIR:-$HOME/.structs-guild-admin}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
SX_TMP_DIR="$CONFIG_DIR/tmp"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'
    PURPLE='\033[0;35m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; DIM=''; BOLD=''; NC=''
fi

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

sx_info()  { echo -e "${CYAN}$*${NC}" >&2; }
sx_ok()    { echo -e "${GREEN}$*${NC}" >&2; }
sx_warn()  { echo -e "${YELLOW}warning:${NC} $*" >&2; }
sx_err()   { echo -e "${RED}error:${NC} $*" >&2; }
sx_die()   { sx_err "$*"; exit 1; }

sx_require() {
    local bin
    for bin in "$STRUCTSD" jq bc; do
        command -v "$bin" >/dev/null 2>&1 || sx_die "'$bin' is required but was not found in PATH"
    done
}

# Ask a yes/no question; honours SX_ASSUME_YES=1
sx_confirm() {
    local prompt="${1:-Proceed?}" answer
    if [ "${SX_ASSUME_YES:-0}" = "1" ]; then return 0; fi
    read -r -p "$prompt (y/n): " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# --------------------------------------------------------------------------
# structsd wrappers
# --------------------------------------------------------------------------

# sx_q <query args...> : JSON query; stderr suppressed, non-zero on failure
sx_q() {
    # shellcheck disable=SC2086
    "$STRUCTSD" query "$@" --output json $STRUCTSD_FLAGS 2>/dev/null
}

# sx_q_all <jq-array-key> <query args...> : walk every page of a paginated
# query and print one compact JSON object per line.
#
# Needed because some structs queries (address-all-by-player in particular)
# filter *within* a page of the global index, so the first page is usually
# empty even when the player has addresses.
sx_q_all() {
    local key_path="$1"; shift
    local page_key="" resp guard=0
    while :; do
        if [ -n "$page_key" ]; then
            resp=$(sx_q "$@" --page-limit 1000 --page-key "$page_key") || return 1
        else
            resp=$(sx_q "$@" --page-limit 1000) || return 1
        fi
        echo "$resp" | jq -c ".${key_path}[]? // empty"
        page_key=$(echo "$resp" | jq -r '.pagination.next_key // empty')
        [ -z "$page_key" ] && break
        guard=$((guard + 1))
        [ $guard -gt 500 ] && { sx_warn "pagination guard hit for: $*"; break; }
    done
}

SX_CHAIN_ID="${STRUCTS_CHAIN_ID:-}"
sx_chain_id() {
    if [ -z "$SX_CHAIN_ID" ]; then
        # `structsd status` only understands --node/--home, so pass just those
        local f=() prev=""
        for a in $STRUCTSD_FLAGS; do
            case "$prev" in --node|--home) f+=("$prev" "$a") ;; esac
            case "$a" in --node=*|--home=*) f+=("$a") ;; esac
            prev="$a"
        done
        SX_CHAIN_ID=$("$STRUCTSD" status "${f[@]+"${f[@]}"}" 2>/dev/null | jq -r '.node_info.network // .NodeInfo.network // empty')
        if [ -z "$SX_CHAIN_ID" ]; then
            sx_err "could not reach a node to detect the chain id (set STRUCTS_CHAIN_ID or STRUCTSD_FLAGS=\"--node ...\")"
            return 1
        fi
    fi
    echo "$SX_CHAIN_ID"
}

# --------------------------------------------------------------------------
# Big-number helpers (bc; amounts can exceed 2^53 for guild tokens)
# --------------------------------------------------------------------------

sx_add()  { echo "${1:-0} + ${2:-0}" | bc; }
sx_sub()  { echo "${1:-0} - ${2:-0}" | bc; }
# sx_cmp a b -> prints -1, 0, 1
sx_cmp()  { echo "a=${1:-0}; b=${2:-0}; if (a<b) -1 else if (a>b) 1 else 0" | bc; }
sx_min()  { if [ "$(sx_cmp "$1" "$2")" = "1" ]; then echo "$2"; else echo "$1"; fi; }
sx_is_zero() { [ "$(sx_cmp "${1:-0}" 0)" = "0" ]; }
# sum newline-separated integers from stdin
sx_sum()  { local s; s=$(grep -E '^[0-9]+$' | paste -sd+ -); [ -z "$s" ] && echo 0 || echo "$s" | bc; }

# --------------------------------------------------------------------------
# Amounts
# --------------------------------------------------------------------------

# Format a base-unit amount for humans: 4000000 ualpha -> "4 alpha"
sx_fmt() {
    local amount="${1:-0}" denom="${2:-ualpha}" whole frac
    case "$denom" in
        ualpha|uguild.*)
            local unit="alpha"
            [ "$denom" != "ualpha" ] && unit="guild.${denom#uguild.}"
            whole=$(echo "$amount / 1000000" | bc)
            frac=$(printf "%06d" "$(echo "$amount % 1000000" | bc)")
            frac=$(echo "$frac" | sed -E 's/0+$//')
            if [ -n "$frac" ]; then echo "${whole}.${frac} ${unit}"; else echo "${whole} ${unit}"; fi
            ;;
        *)  echo "${amount} ${denom}" ;;
    esac
}

# Parse a user-entered amount into "<base-amount> <denom>".
#   1.5alpha | 1.5 alpha -> 1500000 ualpha
#   250ualpha            -> 250 ualpha
#   10guild.0-3          -> 10000000 uguild.0-3
#   500uguild.0-3        -> 500 uguild.0-3
#   1000                 -> error: a number needs a unit (100alpha or 100ualpha?)
#   all [denom]          -> all <denom>
sx_parse_amount() {
    local raw default_denom="${2:-ualpha}"
    raw=$(echo "$1" | tr -d ' ')
    if [[ "$raw" =~ ^all(.*)$ ]]; then
        local d="${BASH_REMATCH[1]}"
        case "$d" in
            ""|alpha|ualpha) echo "all ualpha" ;;
            guild.*) echo "all u$d" ;;
            *) echo "all $d" ;;
        esac
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)(\.([0-9]+))?([a-zA-Z][a-zA-Z0-9./-]*)?$ ]]; then
        local int="${BASH_REMATCH[1]}" dec="${BASH_REMATCH[3]}" denom="${BASH_REMATCH[4]}"
        if [ -z "$denom" ]; then
            # "100" could mean 100 alpha or 100 ualpha (0.0001 alpha) — never guess
            local d="${default_denom#u}"
            if [ -n "$dec" ]; then
                sx_err "$raw needs a unit: ${raw}${d}"
            elif [ "$default_denom" = "ualpha" ] || [[ "$default_denom" == uguild.* ]]; then
                sx_err "$raw needs a unit: ${raw}${d} ($raw $d) or ${raw}${default_denom} ($(sx_fmt "$int" "$default_denom"))"
            else
                sx_err "$raw needs a unit, e.g. ${raw}${default_denom}"
            fi
            return 1
        fi
        case "$denom" in
            alpha|guild.*)
                [ "$denom" = "alpha" ] && denom="ualpha" || denom="u$denom"
                [ ${#dec} -gt 6 ] && { sx_err "too many decimal places in '$1' (max 6)"; return 1; }
                dec=$(printf "%-6s" "$dec" | tr ' ' '0')
                echo "$(echo "$int * 1000000 + $((10#$dec))" | bc) $denom"
                ;;
            *)
                [ -n "$dec" ] && { sx_err "'$denom' amounts must be whole numbers"; return 1; }
                echo "$int $denom"
                ;;
        esac
        return 0
    fi
    sx_err "could not parse amount '$1' (examples: 2.5alpha, 2500000ualpha, all)"
    return 1
}

# --------------------------------------------------------------------------
# Account configuration (shared with guild.sh)
# --------------------------------------------------------------------------

# Populates STRUCTS_ACCOUNT (key name), SX_SIGNER (address), SX_PLAYER_ID.
sx_load_account() {
    mkdir -p "$CONFIG_DIR"
    if [ -z "${STRUCTS_ACCOUNT:-}" ] && [ -f "$CONFIG_FILE" ]; then
        STRUCTS_ACCOUNT=$(jq -r '.account_name // empty' "$CONFIG_FILE")
    fi
    if [ -z "${STRUCTS_ACCOUNT:-}" ]; then
        sx_select_account || return 1
    fi

    # shellcheck disable=SC2086
    SX_SIGNER=$("$STRUCTSD" keys show "$STRUCTS_ACCOUNT" --output json $STRUCTSD_FLAGS 2>/dev/null | jq -r '.address // empty')
    [ -z "$SX_SIGNER" ] && { sx_err "key '$STRUCTS_ACCOUNT' not found in the structsd keyring"; return 1; }

    SX_PLAYER_ID=$(sx_q structs address "$SX_SIGNER" | jq -r '.playerId // empty')
    if [ -z "$SX_PLAYER_ID" ] || [ "$SX_PLAYER_ID" = "1-0" ]; then
        sx_warn "key '$STRUCTS_ACCOUNT' ($SX_SIGNER) is not registered to any player"
        SX_PLAYER_ID=""
    fi
    # keep guild.sh's variable names in sync
    PLAYER_ADDRESS="$SX_SIGNER"; PLAYER_ID="$SX_PLAYER_ID"
    return 0
}

sx_save_account() {
    mkdir -p "$CONFIG_DIR"
    jq -n --arg n "$STRUCTS_ACCOUNT" --arg a "$SX_SIGNER" --arg p "$SX_PLAYER_ID" \
        '{account_name: $n, account_address: $a, account_player_id: $p}' > "$CONFIG_FILE"
}

sx_select_account() {
    local accounts count i choice
    # shellcheck disable=SC2086
    accounts=$("$STRUCTSD" keys list --output json $STRUCTSD_FLAGS 2>/dev/null)
    count=$(echo "$accounts" | jq 'length' 2>/dev/null)
    [ -z "$count" ] || [ "$count" -eq 0 ] && { sx_err "no keys found in the structsd keyring"; return 1; }
    [ -t 0 ] || { sx_err "no account configured; set STRUCTS_ACCOUNT=<key name>"; return 1; }
    echo -e "${CYAN}Select the key you play with:${NC}" >&2
    for ((i = 0; i < count; i++)); do
        echo -e "  ${GREEN}$((i + 1)).${NC} $(echo "$accounts" | jq -r ".[$i].name")  ${DIM}$(echo "$accounts" | jq -r ".[$i].address")${NC}" >&2
    done
    read -r -p "Key (1-$count): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        sx_err "invalid selection"; return 1
    fi
    STRUCTS_ACCOUNT=$(echo "$accounts" | jq -r ".[$((choice - 1))].name")
    SX_SIGNER=$(echo "$accounts" | jq -r ".[$((choice - 1))].address")
    SX_PLAYER_ID=$(sx_q structs address "$SX_SIGNER" | jq -r '.playerId // empty')
    sx_save_account
    sx_ok "Saved account '$STRUCTS_ACCOUNT' to $CONFIG_FILE"
}

# --------------------------------------------------------------------------
# Resolution helpers
# --------------------------------------------------------------------------

sx_is_address()   { [[ "$1" =~ ^structs1[02-9ac-hj-np-z]{38,}$ ]]; }
sx_is_valoper()   { [[ "$1" =~ ^structsvaloper1[02-9ac-hj-np-z]{38,}$ ]]; }
sx_is_player_id() { [[ "$1" =~ ^1-[0-9]+$ ]]; }
sx_is_guild_id()  { [[ "$1" =~ ^0-[0-9]+$ ]]; }
sx_is_reactor_id(){ [[ "$1" =~ ^3-[0-9]+$ ]]; }

# Address or player id -> player id ("" if unregistered)
sx_player_of() {
    if sx_is_player_id "$1"; then echo "$1"; return; fi
    local p
    p=$(sx_q structs address "$1" | jq -r '.playerId // empty')
    # Vault addresses are not registered addresses; fall back to a reverse lookup
    # is not available on-chain, so callers should pass a player id for vaults.
    [ "$p" = "1-0" ] && p=""
    echo "$p"
}

sx_vault_of() { sx_q structs vault "$1" | jq -r '.address // empty'; }

# --------------------------------------------------------------------------
# Validator / reactor directory (cached per run)
# --------------------------------------------------------------------------

SX_VALIDATORS_JSON=""
sx_load_validators() {
    [ -n "$SX_VALIDATORS_JSON" ] && return 0
    local vals reactors
    vals=$(sx_q_all validators staking validators | jq -s 'map({key: .operator_address, value: {moniker: .description.moniker, status: .status, jailed: (.jailed // false), tokens: .tokens}}) | from_entries')
    reactors=$(sx_q_all Reactor structs reactor-all | jq -s 'map({key: .validator, value: {reactorId: .id, owner: .owner, guildId: (.guildId // "")}}) | from_entries')
    [ -z "$vals" ] && vals='{}'
    [ -z "$reactors" ] && reactors='{}'
    SX_VALIDATORS_JSON=$(jq -n --argjson v "$vals" --argjson r "$reactors" \
        '($v | keys) + ($r | keys) | unique | map({key: ., value: (($v[.] // {}) + ($r[.] // {}))}) | from_entries')
}

# "Moniker (3-12)" label for a validator operator address
sx_validator_label() {
    sx_load_validators
    echo "$SX_VALIDATORS_JSON" | jq -r --arg v "$1" '
        .[$v] as $x | if $x == null then $v
        else "\($x.moniker // "unknown") (\($x.reactorId // "no reactor"))\(if $x.jailed then " [JAILED]" elif ($x.status // "") != "BOND_STATUS_BONDED" and $x.status != null then " [\($x.status | sub("BOND_STATUS_"; ""))]" else "" end)" end'
}

# Resolve a validator target: valoper | reactor id (3-N) | player id owning a
# reactor (1-N) | guild id (0-N, its primary reactor) | moniker
sx_resolve_validator() {
    local t="$1"
    sx_load_validators
    if sx_is_valoper "$t"; then echo "$t"; return 0; fi
    local v=""
    if sx_is_reactor_id "$t"; then
        v=$(echo "$SX_VALIDATORS_JSON" | jq -r --arg t "$t" 'to_entries[] | select(.value.reactorId == $t) | .key' | head -1)
    elif sx_is_player_id "$t"; then
        v=$(echo "$SX_VALIDATORS_JSON" | jq -r --arg t "$t" 'to_entries[] | select(.value.owner == $t) | .key' | head -1)
    elif sx_is_guild_id "$t"; then
        local rid
        rid=$(sx_q structs guild "$t" | jq -r '.Guild.primaryReactorId // empty')
        [ -n "$rid" ] && v=$(echo "$SX_VALIDATORS_JSON" | jq -r --arg t "$rid" 'to_entries[] | select(.value.reactorId == $t) | .key' | head -1)
    else
        v=$(echo "$SX_VALIDATORS_JSON" | jq -r --arg t "$t" 'to_entries[] | select((.value.moniker // "" | ascii_downcase) == ($t | ascii_downcase)) | .key' | head -1)
    fi
    [ -z "$v" ] && { sx_err "could not resolve validator '$t' (use a structsvaloper address, reactor id 3-N, player id, guild id or moniker)"; return 1; }
    echo "$v"
}

# --------------------------------------------------------------------------
# Transaction engine
# --------------------------------------------------------------------------
#
# Messages are queued as argument strings for `structsd tx`, e.g.
#   sx_tx_add structs player-send <from> <to> 100ualpha
# then executed with sx_tx_run "<description>".
#
# One message  -> a normal `structsd tx ... --gas auto` broadcast.
# Many messages -> each is simulated individually (--generate-only --gas auto,
# which validates it against chain state), the messages are merged into ONE
# transaction, signed once and broadcast. All parts succeed or fail together.

SX_TX_MSGS=()

# Print structsd error output without the cobra usage/flags dump
sx_tx_clean_err() {
    grep -vE '^(Usage:|Flags:|Global Flags:|  |gas estimate:|$)' | grep -v 'for more information about a command' | sed 's/^/    /' >&2
}

sx_tx_reset() { SX_TX_MSGS=(); }

# Quote each argument so it survives being stored in a string
sx_tx_add() {
    local s="" a
    for a in "$@"; do s="$s $(printf '%q' "$a")"; done
    SX_TX_MSGS+=("$s")
}

sx_tx_count() { echo "${#SX_TX_MSGS[@]}"; }

sx_tx_common_flags() {
    echo "--from $(printf '%q' "$STRUCTS_ACCOUNT") --chain-id $(sx_chain_id) $STRUCTSD_FLAGS $STRUCTSD_TX_FLAGS"
}

# Wait for a tx hash to land; prints the tx JSON. Returns 1 if not found.
sx_tx_wait() {
    local hash="$1" i resp
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 2
        resp=$(sx_q tx "$hash") && [ -n "$resp" ] && { echo "$resp"; return 0; }
    done
    return 1
}

sx_tx_report() {
    local hash="$1" result code log
    if [ -z "$hash" ]; then sx_err "no transaction hash returned"; return 1; fi
    sx_info "Submitted tx $hash — waiting for it to be included..."
    if result=$(sx_tx_wait "$hash"); then
        code=$(echo "$result" | jq -r '.code // 0')
        if [ "$code" = "0" ]; then
            sx_ok "Confirmed in block $(echo "$result" | jq -r .height): $hash"
            return 0
        fi
        log=$(echo "$result" | jq -r '.raw_log // empty')
        sx_err "transaction failed (code $code): $log"
        return 1
    fi
    sx_warn "not confirmed yet; check later with: structsd query tx $hash"
    return 0
}

# sx_tx_run [--dry-run]
sx_tx_run() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    [ "${SX_DRY_RUN:-0}" = "1" ] && dry=1
    local n=${#SX_TX_MSGS[@]}
    [ "$n" -eq 0 ] && { sx_warn "nothing to do"; return 0; }
    [ -z "${STRUCTS_ACCOUNT:-}" ] && { sx_err "no signing key configured"; return 1; }
    mkdir -p "$SX_TMP_DIR"

    local flags out hash
    # resolve the chain id in this shell so it is cached and errors stop us here
    if [ -z "$SX_CHAIN_ID" ]; then
        SX_CHAIN_ID=$(sx_chain_id) || return 1
    fi
    flags=$(sx_tx_common_flags)

    if [ "$n" -eq 1 ] && [ "$dry" -eq 0 ]; then
        out=$(eval "\"$STRUCTSD\" tx ${SX_TX_MSGS[0]} $flags --gas auto --gas-adjustment $SX_GAS_ADJUSTMENT --yes --output json" 2>&1)
        hash=$(echo "$out" | grep -E '^\{' | tail -1 | jq -r '.txhash // empty' 2>/dev/null)
        local code
        code=$(echo "$out" | grep -E '^\{' | tail -1 | jq -r '.code // 0' 2>/dev/null)
        if [ -z "$hash" ] || [ "${code:-0}" != "0" ]; then
            sx_err "transaction rejected:"; echo "$out" | sx_tx_clean_err
            return 1
        fi
        sx_tx_report "$hash"
        return $?
    fi

    # Multi-message (or dry run): simulate each message, then merge.
    local i gen gas total_gas=0 merged="" unsigned signed
    unsigned="$SX_TMP_DIR/tx-unsigned-$$.json"
    signed="$SX_TMP_DIR/tx-signed-$$.json"
    for ((i = 0; i < n; i++)); do
        gen=$(eval "\"$STRUCTSD\" tx ${SX_TX_MSGS[$i]} $flags --generate-only --gas auto --gas-adjustment $SX_GAS_ADJUSTMENT" 2>&1)
        if ! echo "$gen" | grep -qE '^\{'; then
            sx_err "simulation failed for step $((i + 1)) of $n:"
            echo "$gen" | sx_tx_clean_err
            return 1
        fi
        gen=$(echo "$gen" | grep -E '^\{' | tail -1)
        gas=$(echo "$gen" | jq -r '.auth_info.fee.gas_limit')
        total_gas=$((total_gas + gas))
        if [ -z "$merged" ]; then
            merged="$gen"
        else
            merged=$(jq -c --argjson b "$gen" '.body.messages += $b.body.messages' <<<"$merged")
        fi
    done
    merged=$(jq -c --arg g "$total_gas" '.auth_info.fee.gas_limit = $g' <<<"$merged")

    if [ "$dry" -eq 1 ]; then
        sx_ok "Dry run: all $n message(s) simulated successfully (total gas ~$total_gas). Nothing was broadcast."
        return 0
    fi

    echo "$merged" > "$unsigned"
    # shellcheck disable=SC2086
    if ! eval "\"$STRUCTSD\" tx sign \"$unsigned\" $flags --output-document \"$signed\"" >/dev/null 2>"$signed.err"; then
        sx_err "signing failed:"; sx_tx_clean_err < "$signed.err"
        rm -f "$unsigned" "$signed" "$signed.err"
        return 1
    fi
    # shellcheck disable=SC2086
    out=$("$STRUCTSD" tx broadcast "$signed" --output json $STRUCTSD_FLAGS 2>&1)
    rm -f "$unsigned" "$signed" "$signed.err"
    hash=$(echo "$out" | grep -E '^\{' | tail -1 | jq -r '.txhash // empty' 2>/dev/null)
    local bcode
    bcode=$(echo "$out" | grep -E '^\{' | tail -1 | jq -r '.code // 0' 2>/dev/null)
    if [ -z "$hash" ] || [ "${bcode:-0}" != "0" ]; then
        sx_err "broadcast rejected:"; echo "$out" | sx_tx_clean_err
        return 1
    fi
    sx_tx_report "$hash"
}
