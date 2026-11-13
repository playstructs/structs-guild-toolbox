#!/bin/bash
#
# structs-wallet.sh — unified player wallet
#
# A Structs player account is more than one address:
#   * the Player Vault  (query structs vault <player-id>) — a module-controlled
#     address that any of the player's registered keys can spend from
#   * every registered address (query structs address-all-by-player <player-id>),
#     one of which is the primary address
#
# Funds and delegations can sit on any of them. This module treats them as one
# wallet: it shows the combined balance and delegations, and when you spend,
# delegate or undelegate it works out which sources to draw from and bundles
# the pieces into a single atomic transaction.
#
# Requires structs-lib.sh to be sourced first.

SX_WALLET=""        # JSON document describing the loaded player account
SX_WALLET_PLAYER="" # player id of the loaded wallet

# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

# sx_wallet_load <player-id | address>
sx_wallet_load() {
    local target="$1" pid player vault addrs local_keys
    pid=$(sx_player_of "$target")
    [ -z "$pid" ] && { sx_err "'$target' is not a registered player address or player id"; return 1; }

    player=$(sx_q structs player "$pid")
    [ -z "$player" ] || [ "$(echo "$player" | jq -r '.Player.id // empty')" = "" ] && { sx_err "player $pid not found"; return 1; }
    vault=$(sx_vault_of "$pid")

    addrs=$(sx_q_all address structs address-all-by-player "$pid" | jq -s 'map({address, permissions})')
    [ -z "$addrs" ] && addrs='[]'

    # shellcheck disable=SC2086
    local_keys=$("$STRUCTSD" keys list --output json $STRUCTSD_FLAGS 2>/dev/null | jq -c 'map(.address)' 2>/dev/null)
    [ -z "$local_keys" ] && local_keys='[]'

    local primary
    primary=$(echo "$player" | jq -r '.Player.primaryAddress // empty')

    # Ordered list of sources: vault, primary, then the other registered addresses
    local list
    list=$(jq -n --arg vault "$vault" --arg primary "$primary" --argjson addrs "$addrs" '
        ( if $vault != "" then [{address: $vault, kind: "vault", permissions: null}] else [] end )
        + [ $addrs[] | select(.address == $primary) | . + {kind: "primary"} ]
        + [ $addrs[] | select(.address != $primary) | . + {kind: "address"} ]
        + ( if $primary != "" and ([$addrs[].address] | index($primary)) == null
            then [{address: $primary, kind: "primary", permissions: null}] else [] end )')

    local sources="[]" addr kind bal dels unb rew perms
    while read -r src; do
        addr=$(echo "$src" | jq -r .address)
        kind=$(echo "$src" | jq -r .kind)
        perms=$(echo "$src" | jq -c .permissions)
        bal=$(sx_q bank balances "$addr" | jq -c '.balances // []')
        dels=$(sx_q staking delegations "$addr" | jq -c '[.delegation_responses[]? | {validator: .delegation.validator_address, amount: .balance.amount}] | map(select(.amount != "0"))')
        unb=$(sx_q staking unbonding-delegations "$addr" | jq -c '[.unbonding_responses[]? | .validator_address as $v | .entries[] | {validator: $v, creation_height: .creation_height, completion_time: .completion_time, balance: .balance}]')
        rew=$(sx_q distribution rewards "$addr" | jq -c '[.total[]? | if type == "string" then (capture("^(?<amount>[0-9.]+)(?<denom>.+)$")) else . end]' 2>/dev/null)
        sources=$(jq -c \
            --arg a "$addr" --arg k "$kind" --argjson p "${perms:-null}" --argjson lk "$local_keys" \
            --argjson b "${bal:-[]}" --argjson d "${dels:-[]}" --argjson u "${unb:-[]}" --argjson r "${rew:-[]}" \
            '. + [{address: $a, kind: $k, permissions: $p, local: ($lk | index($a) != null),
                   balances: $b, delegations: $d, unbonding: $u, rewards: $r}]' <<<"$sources")
    done < <(echo "$list" | jq -c '.[]')

    SX_WALLET=$(jq -n --argjson p "$player" --arg vault "$vault" --argjson s "$sources" '{
        playerId: $p.Player.id,
        name: ($p.Player.name // ""),
        guildId: ($p.Player.guildId // ""),
        primaryAddress: ($p.Player.primaryAddress // ""),
        vault: $vault,
        sources: $s }')
    SX_WALLET_PLAYER="$pid"
}

# --------------------------------------------------------------------------
# Derived values
# --------------------------------------------------------------------------

sx_w_liquid()     { echo "$SX_WALLET" | jq -r --arg d "${1:-ualpha}" '.sources[].balances[] | select(.denom == $d) | .amount' | sx_sum; }
sx_w_delegated()  { echo "$SX_WALLET" | jq -r '.sources[].delegations[].amount' | sx_sum; }
sx_w_unbonding()  { echo "$SX_WALLET" | jq -r '.sources[].unbonding[].balance' | sx_sum; }
sx_w_rewards()    { echo "$SX_WALLET" | jq -r '[.sources[].rewards[]? | select(.denom == "ualpha") | .amount | tonumber] | add // 0 | floor'; }
sx_w_denoms()     { echo "$SX_WALLET" | jq -r '[.sources[].balances[].denom] | unique | .[]'; }

# Short label for a source: "Vault", "Primary wallet", "Wallet structs1abc…xyz"
sx_w_label() {
    local addr="$1"
    echo "$SX_WALLET" | jq -r --arg a "$addr" '
        (.sources[] | select(.address == $a)) as $s
        | if $s == null then $a
          elif $s.kind == "vault" then "Player Vault"
          elif $s.kind == "primary" then "Primary wallet"
          else "Wallet \($a[0:12])…\($a[-6:])" end'
}

# Can the configured key sign for this wallet?
sx_w_can_sign() {
    [ -n "${SX_SIGNER:-}" ] && [ "${SX_PLAYER_ID:-}" = "$SX_WALLET_PLAYER" ]
}

sx_w_require_signer() {
    if ! sx_w_can_sign; then
        sx_err "your key '${STRUCTS_ACCOUNT:-?}' (${SX_SIGNER:-?}) belongs to player '${SX_PLAYER_ID:-none}', not $SX_WALLET_PLAYER — you can view this account but not spend from it"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Display
# --------------------------------------------------------------------------

sx_w_short() { local a="$1"; echo "${a:0:14}…${a: -6}"; }

sx_wallet_show() {
    local liquid delegated unbonding rewards total
    liquid=$(sx_w_liquid ualpha)
    delegated=$(sx_w_delegated)
    unbonding=$(sx_w_unbonding)
    rewards=$(sx_w_rewards)
    total=$(sx_add "$(sx_add "$liquid" "$delegated")" "$unbonding")

    local name guild
    name=$(echo "$SX_WALLET" | jq -r '.name')
    guild=$(echo "$SX_WALLET" | jq -r '.guildId')

    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BOLD} PLAYER ${SX_WALLET_PLAYER}${NC}${name:+  ·  $name}${guild:+  ·  guild $guild}"
    echo -e "${BLUE}======================================================${NC}"
    if sx_w_can_sign; then
        echo -e " Signing with: ${GREEN}${STRUCTS_ACCOUNT}${NC} ${DIM}($(sx_w_label "$SX_SIGNER"))${NC}"
    else
        echo -e " ${YELLOW}View only${NC} — your configured key does not belong to this player"
    fi
    echo ""
    echo -e "${CYAN} ALPHA BALANCE${NC}"
    printf "   %-28s %24s\n" "Available to spend" "$(sx_fmt "$liquid")"
    printf "   %-28s %24s\n" "Delegated (infused)" "$(sx_fmt "$delegated")"
    sx_is_zero "$unbonding" || printf "   %-28s %24s\n" "Defusing (unbonding)" "$(sx_fmt "$unbonding")"
    sx_is_zero "$rewards" || printf "   %-28s %24s\n" "Unclaimed staking rewards" "$(sx_fmt "$rewards")"
    printf "   %-28s %24s\n" "" "------------------------"
    printf "   ${BOLD}%-28s %24s${NC}\n" "Total" "$(sx_fmt "$total")"

    local others
    others=$(sx_w_denoms | grep -v '^ualpha$')
    if [ -n "$others" ]; then
        echo ""
        echo -e "${CYAN} OTHER TOKENS${NC}"
        local d
        for d in $others; do
            printf "   %-28s %24s\n" "$d" "$(sx_fmt "$(sx_w_liquid "$d")" "$d")"
        done
    fi

    echo ""
    echo -e "${CYAN} WHERE THE ALPHA IS${NC}  ${DIM}(every source is spendable by any of the player's registered keys)${NC}"
    printf "   ${DIM}%-16s %-24s %16s %16s${NC}\n" "SOURCE" "ADDRESS" "AVAILABLE" "DELEGATED"
    local src addr kind tag avail deleg
    while read -r src; do
        addr=$(echo "$src" | jq -r .address)
        kind=$(echo "$src" | jq -r .kind)
        avail=$(echo "$src" | jq -r '.balances[] | select(.denom == "ualpha") | .amount' | sx_sum)
        deleg=$(echo "$src" | jq -r '.delegations[].amount' | sx_sum)
        case "$kind" in
            vault) tag="Player Vault" ;;
            primary) tag="Primary wallet" ;;
            *) tag="Wallet" ;;
        esac
        [ "$addr" = "${SX_SIGNER:-}" ] && tag="$tag *"
        printf "   %-16s %-24s %16s %16s\n" "$tag" "$(sx_w_short "$addr")" "$(sx_fmt "$avail" | sed 's/ alpha//')" "$(sx_fmt "$deleg" | sed 's/ alpha//')"
    done < <(echo "$SX_WALLET" | jq -c '.sources[]')
    [ -n "${SX_SIGNER:-}" ] && sx_w_can_sign && echo -e "   ${DIM}* = the key you are signing with${NC}"

    sx_wallet_show_delegations
}

sx_wallet_show_delegations() {
    local rows
    rows=$(echo "$SX_WALLET" | jq -c '[.sources[] | .address as $a | .delegations[] | . + {from: $a}] | group_by(.validator) | .[]')
    echo ""
    echo -e "${CYAN} DELEGATIONS${NC}"
    if [ -z "$rows" ]; then
        echo "   (none)"
    else
        local g v total
        while read -r g; do
            v=$(echo "$g" | jq -r '.[0].validator')
            total=$(echo "$g" | jq -r '.[].amount' | sx_sum)
            printf "   %-40s %24s\n" "$(sx_validator_label "$v")" "$(sx_fmt "$total")"
            if [ "$(echo "$g" | jq length)" -gt 1 ] || [ "${SX_VERBOSE:-0}" = "1" ]; then
                echo "$g" | jq -r '.[] | "\(.from) \(.amount)"' | while read -r a amt; do
                    printf "     ${DIM}%-38s %24s${NC}\n" "via $(sx_w_label "$a")" "$(sx_fmt "$amt")"
                done
            else
                printf "     ${DIM}%s${NC}\n" "via $(sx_w_label "$(echo "$g" | jq -r '.[0].from')")"
            fi
        done <<<"$rows"
    fi

    local unb
    unb=$(echo "$SX_WALLET" | jq -c '[.sources[] | .address as $a | .unbonding[] | . + {from: $a}] | sort_by(.completion_time) | to_entries[]')
    if [ -n "$unb" ]; then
        echo ""
        echo -e "${CYAN} DEFUSING${NC}  ${DIM}(returns to the source when complete; cancel with: cancel-defuse <#>)${NC}"
        local e idx
        while read -r e; do
            idx=$(( $(echo "$e" | jq -r .key) + 1 ))
            printf "   #%-3s %-34s %18s  ready %s  ${DIM}(%s)${NC}\n" "$idx" \
                "$(sx_validator_label "$(echo "$e" | jq -r .value.validator)")" \
                "$(sx_fmt "$(echo "$e" | jq -r .value.balance)")" \
                "$(echo "$e" | jq -r '.value.completion_time | sub("\\.[0-9]+Z$"; "Z")')" \
                "$(sx_w_label "$(echo "$e" | jq -r .value.from)")"
        done <<<"$unb"
    fi
}

# --------------------------------------------------------------------------
# Planning
# --------------------------------------------------------------------------
#
# A plan is newline-separated "address amount" pairs. Planners print the plan
# to stdout and return 1 (with an error) if the wallet cannot cover the amount.

# Resolve a --from selector (vault | primary | address) to an address
sx_w_source_address() {
    case "$1" in
        vault) echo "$SX_WALLET" | jq -r '.vault' ;;
        primary) echo "$SX_WALLET" | jq -r '.primaryAddress' ;;
        *) echo "$SX_WALLET" | jq -r --arg a "$1" '.sources[] | select(.address == $a) | .address' ;;
    esac
}

# sx_w_plan_liquid <amount|all> <denom> [only-address] [exclude-address]
sx_w_plan_liquid() {
    local want="$1" denom="$2" only="${3:-}" exclude="${4:-}"
    local candidates remaining addr bal take plan="" available
    candidates=$(echo "$SX_WALLET" | jq -r --arg d "$denom" --arg only "$only" --arg ex "$exclude" '
        .sources[] | select(($only == "" or .address == $only) and .address != $ex)
        | "\(.address) \([.balances[] | select(.denom == $d) | .amount][0] // "0")"')
    available=$(echo "$candidates" | awk '{print $2}' | sx_sum)
    if [ "$want" = "all" ]; then want="$available"; fi
    if sx_is_zero "$want"; then sx_err "nothing to move: available $(sx_fmt "$available" "$denom")"; return 1; fi
    if [ "$(sx_cmp "$available" "$want")" = "-1" ]; then
        sx_err "insufficient funds: need $(sx_fmt "$want" "$denom"), available $(sx_fmt "$available" "$denom")${only:+ in that source}"
        return 1
    fi
    remaining="$want"
    while read -r addr bal; do
        [ -z "$addr" ] && continue
        sx_is_zero "$remaining" && break
        sx_is_zero "$bal" && continue
        take=$(sx_min "$bal" "$remaining")
        plan="${plan}${addr} ${take}"$'\n'
        remaining=$(sx_sub "$remaining" "$take")
    done <<<"$candidates"
    printf "%s" "$plan"
}

# sx_w_plan_delegation <validator> <amount|all> [only-address]
# Draws from the largest delegations first to keep the transaction small.
sx_w_plan_delegation() {
    local val="$1" want="$2" only="${3:-}"
    local candidates remaining addr bal take plan="" available
    candidates=$(echo "$SX_WALLET" | jq -r --arg v "$val" --arg only "$only" '
        [.sources[] | select($only == "" or .address == $only) | .address as $a
         | .delegations[] | select(.validator == $v) | {a: $a, amt: .amount}]
        | sort_by(.amt | tonumber) | reverse | .[] | "\(.a) \(.amt)"')
    available=$(echo "$candidates" | awk '{print $2}' | sx_sum)
    [ "$want" = "all" ] && want="$available"
    if sx_is_zero "$want"; then sx_err "no delegation to $(sx_validator_label "$val")${only:+ from that source}"; return 1; fi
    if [ "$(sx_cmp "$available" "$want")" = "-1" ]; then
        sx_err "only $(sx_fmt "$available") is delegated to $(sx_validator_label "$val")"
        return 1
    fi
    remaining="$want"
    while read -r addr bal; do
        [ -z "$addr" ] && continue
        sx_is_zero "$remaining" && break
        take=$(sx_min "$bal" "$remaining")
        plan="${plan}${addr} ${take}"$'\n'
        remaining=$(sx_sub "$remaining" "$take")
    done <<<"$candidates"
    printf "%s" "$plan"
}

sx_w_print_plan() {
    local plan="$1" denom="$2" verb="${3:-from}" addr amt
    while read -r addr amt; do
        [ -z "$addr" ] && continue
        printf "     %18s  %s %s ${DIM}(%s)${NC}\n" "$(sx_fmt "$amt" "$denom")" "$verb" "$(sx_w_label "$addr")" "$(sx_w_short "$addr")"
    done <<<"$plan"
}

sx_w_plan_steps() { echo "$1" | grep -c . ; }

sx_w_execute() {
    local steps
    steps=$(sx_tx_count)
    if [ "$steps" -gt 1 ]; then
        echo -e "   ${DIM}$steps messages, bundled into one transaction (all succeed or none do)${NC}"
    fi
    echo ""
    if [ "${SX_DRY_RUN:-0}" = "1" ]; then
        sx_tx_run --dry-run
        return $?
    fi
    sx_confirm "Sign and broadcast?" || { sx_warn "cancelled"; return 1; }
    sx_tx_run
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------

# Resolve a send recipient: address, or player id (-> that player's vault)
sx_w_resolve_recipient() {
    local r="$1"
    if sx_is_address "$r"; then echo "$r"; return 0; fi
    if sx_is_player_id "$r"; then
        local v
        v=$(sx_vault_of "$r")
        [ -z "$v" ] && { sx_err "player $r has no vault"; return 1; }
        echo "$v"; return 0
    fi
    sx_err "recipient must be a structs1… address or a player id (1-N)"
    return 1
}

# sx_wallet_send <recipient> <amount> [from-selector]
sx_wallet_send() {
    local to_raw="$1" amount_raw="$2" from_sel="${3:-}"
    sx_w_require_signer || return 1
    local to parsed want denom only="" plan
    to=$(sx_w_resolve_recipient "$to_raw") || return 1
    parsed=$(sx_parse_amount "$amount_raw") || return 1
    want=${parsed% *}; denom=${parsed#* }
    if [ -n "$from_sel" ]; then
        only=$(sx_w_source_address "$from_sel")
        [ -z "$only" ] && { sx_err "'$from_sel' is not part of this player account"; return 1; }
    fi
    plan=$(sx_w_plan_liquid "$want" "$denom" "$only" "$to") || return 1
    [ "$want" = "all" ] && want=$(echo "$plan" | awk '{print $2}' | sx_sum)

    echo ""
    echo -e "${CYAN} SEND $(sx_fmt "$want" "$denom")${NC} to ${BOLD}$to${NC}"
    sx_is_player_id "$to_raw" && echo -e "   ${DIM}(Player Vault of $to_raw)${NC}"
    local own
    own=$(echo "$SX_WALLET" | jq -r --arg a "$to" '.sources[] | select(.address == $a) | .kind')
    [ -n "$own" ] && echo -e "   ${DIM}(this is your own $(sx_w_label "$to") — an internal move)${NC}"
    sx_w_print_plan "$plan" "$denom"

    sx_tx_reset
    local addr amt
    while read -r addr amt; do
        [ -z "$addr" ] && continue
        sx_tx_add structs player-send "$addr" "$to" "${amt}${denom}"
    done <<<"$plan"
    sx_w_execute
}

# sx_wallet_consolidate <vault|primary|address> [denom|all]
sx_wallet_consolidate() {
    local target_sel="${1:-primary}" denom_sel="${2:-ualpha}"
    sx_w_require_signer || return 1
    local target
    target=$(sx_w_source_address "$target_sel")
    [ -z "$target" ] && { sx_err "'$target_sel' is not part of this player account"; return 1; }
    local denoms d plan any=0
    if [ "$denom_sel" = "all" ]; then denoms=$(sx_w_denoms); else
        denoms=$(sx_parse_amount "0$denom_sel" 2>/dev/null | awk '{print $2}'); [ -z "$denoms" ] && denoms="$denom_sel"
    fi
    echo ""
    echo -e "${CYAN} CONSOLIDATE into $(sx_w_label "$target")${NC} ${DIM}($target)${NC}"
    sx_tx_reset
    for d in $denoms; do
        plan=$(sx_w_plan_liquid all "$d" "" "$target" 2>/dev/null) || continue
        any=1
        sx_w_print_plan "$plan" "$d"
        local addr amt
        while read -r addr amt; do
            [ -z "$addr" ] && continue
            sx_tx_add structs player-send "$addr" "$target" "${amt}${d}"
        done <<<"$plan"
    done
    [ $any -eq 0 ] && { sx_ok "Nothing to move — everything is already in $(sx_w_label "$target")."; return 0; }
    sx_w_execute
}

# Warn when a reactor's stake cap would reject the infusion
sx_w_check_stake_cap() {
    local val="$1" amount="$2" rid share active headroom
    sx_load_validators
    rid=$(echo "$SX_VALIDATORS_JSON" | jq -r --arg v "$val" '.[$v].reactorId // empty')
    [ -z "$rid" ] && { sx_warn "$val is not a Structs reactor"; return 0; }
    share=$(sx_q structs reactor-stake-share "$rid") || return 0
    active=$(echo "$share" | jq -r '.capActive // false')
    headroom=$(echo "$share" | jq -r '.externalDepositHeadroom // empty')
    if [ "$active" = "true" ] && [ -n "$headroom" ] && [ "$(sx_cmp "$amount" "$headroom")" = "1" ]; then
        sx_warn "reactor $rid is near its stake cap: only $(sx_fmt "$headroom") of new delegation fits right now"
    fi
}

# sx_wallet_delegate <validator-target> <amount> [from-selector]
sx_wallet_delegate() {
    local target="$1" amount_raw="$2" from_sel="${3:-}"
    sx_w_require_signer || return 1
    local val parsed want denom only="" plan
    val=$(sx_resolve_validator "$target") || return 1
    parsed=$(sx_parse_amount "$amount_raw") || return 1
    want=${parsed% *}; denom=${parsed#* }
    [ "$denom" != "ualpha" ] && { sx_err "only alpha can be delegated"; return 1; }
    if [ -n "$from_sel" ]; then
        only=$(sx_w_source_address "$from_sel")
        [ -z "$only" ] && { sx_err "'$from_sel' is not part of this player account"; return 1; }
    fi
    plan=$(sx_w_plan_liquid "$want" ualpha "$only") || return 1
    [ "$want" = "all" ] && want=$(echo "$plan" | awk '{print $2}' | sx_sum)

    echo ""
    echo -e "${CYAN} DELEGATE $(sx_fmt "$want")${NC} to ${BOLD}$(sx_validator_label "$val")${NC}"
    sx_w_check_stake_cap "$val" "$want"
    sx_w_print_plan "$plan" ualpha

    sx_tx_reset
    local addr amt
    while read -r addr amt; do
        [ -z "$addr" ] && continue
        sx_tx_add structs reactor-infuse "$val" "${amt}ualpha" --delegator-address "$addr"
    done <<<"$plan"
    sx_w_execute
}

# sx_wallet_undelegate <validator-target> <amount|all> [from-selector]
sx_wallet_undelegate() {
    local target="$1" amount_raw="$2" from_sel="${3:-}"
    sx_w_require_signer || return 1
    local val parsed want only="" plan
    val=$(sx_resolve_validator "$target") || return 1
    parsed=$(sx_parse_amount "$amount_raw") || return 1
    want=${parsed% *}
    [ "${parsed#* }" != "ualpha" ] && { sx_err "delegations are in alpha"; return 1; }
    [ -n "$from_sel" ] && only=$(sx_w_source_address "$from_sel")
    plan=$(sx_w_plan_delegation "$val" "$want" "$only") || return 1
    [ "$want" = "all" ] && want=$(echo "$plan" | awk '{print $2}' | sx_sum)

    local unbond_time
    unbond_time=$(sx_q staking params | jq -r '.params.unbonding_time // empty')
    echo ""
    echo -e "${CYAN} UNDELEGATE (defuse) $(sx_fmt "$want")${NC} from ${BOLD}$(sx_validator_label "$val")${NC}"
    echo -e "   ${DIM}Funds return to the address they were delegated from after the cooldown${unbond_time:+ ($unbond_time)}.${NC}"
    sx_w_print_plan "$plan" ualpha

    sx_tx_reset
    local addr amt
    while read -r addr amt; do
        [ -z "$addr" ] && continue
        sx_tx_add structs reactor-defuse "$val" "${amt}ualpha" --delegator-address "$addr"
    done <<<"$plan"
    sx_w_execute
}

# sx_wallet_redelegate <from-validator> <to-validator> <amount|all>
sx_wallet_redelegate() {
    local src_t="$1" dst_t="$2" amount_raw="$3"
    sx_w_require_signer || return 1
    local src dst parsed want plan
    src=$(sx_resolve_validator "$src_t") || return 1
    dst=$(sx_resolve_validator "$dst_t") || return 1
    [ "$src" = "$dst" ] && { sx_err "source and destination are the same validator"; return 1; }
    parsed=$(sx_parse_amount "$amount_raw") || return 1
    want=${parsed% *}
    plan=$(sx_w_plan_delegation "$src" "$want") || return 1
    [ "$want" = "all" ] && want=$(echo "$plan" | awk '{print $2}' | sx_sum)

    echo ""
    echo -e "${CYAN} MOVE DELEGATION $(sx_fmt "$want")${NC}"
    echo -e "   from ${BOLD}$(sx_validator_label "$src")${NC}"
    echo -e "   to   ${BOLD}$(sx_validator_label "$dst")${NC}"
    sx_w_check_stake_cap "$dst" "$want"
    sx_w_print_plan "$plan" ualpha "held by"

    sx_tx_reset
    local addr amt
    while read -r addr amt; do
        [ -z "$addr" ] && continue
        sx_tx_add structs reactor-begin-migration "$src" "$dst" "${amt}ualpha" --delegator-address "$addr"
    done <<<"$plan"
    sx_w_execute
}

# sx_wallet_cancel_defuse <#> [amount]
sx_wallet_cancel_defuse() {
    local idx="$1" amount_raw="${2:-}"
    sx_w_require_signer || return 1
    local entry
    entry=$(echo "$SX_WALLET" | jq -c --argjson i "$((idx - 1))" '[.sources[] | .address as $a | .unbonding[] | . + {from: $a}] | sort_by(.completion_time) | .[$i] // empty')
    [ -z "$entry" ] && { sx_err "no defusing entry #$idx (see the DEFUSING list in the wallet view)"; return 1; }
    local val height bal from amt
    val=$(echo "$entry" | jq -r .validator)
    height=$(echo "$entry" | jq -r .creation_height)
    bal=$(echo "$entry" | jq -r .balance)
    from=$(echo "$entry" | jq -r .from)
    amt="$bal"
    if [ -n "$amount_raw" ]; then
        amt=$(sx_parse_amount "$amount_raw" | awk '{print $1}') || return 1
        [ "$(sx_cmp "$amt" "$bal")" = "1" ] && { sx_err "entry #$idx only has $(sx_fmt "$bal")"; return 1; }
    fi
    echo ""
    echo -e "${CYAN} CANCEL DEFUSION${NC} of $(sx_fmt "$amt") back into ${BOLD}$(sx_validator_label "$val")${NC}"
    echo -e "   ${DIM}held by $(sx_w_label "$from"), started at height $height${NC}"
    sx_tx_reset
    sx_tx_add structs reactor-cancel-defusion "$val" "${amt}ualpha" "$height" --delegator-address "$from"
    sx_w_execute
}

# --------------------------------------------------------------------------
# Interactive menu
# --------------------------------------------------------------------------

sx_wallet_menu() {
    local who="${1:-$SX_PLAYER_ID}" opt a b c
    [ -z "$who" ] && { read -r -p "Player id or address to view: " who; }
    while :; do
        clear 2>/dev/null
        sx_info "Loading player account $who..."
        sx_wallet_load "$who" || { read -r -p "Press Enter to continue..." _; return 1; }
        clear 2>/dev/null
        sx_wallet_show
        echo ""
        echo -e "${CYAN} OPTIONS${NC}"
        echo -e "   ${GREEN}1.${NC} Refresh            ${GREEN}5.${NC} Move delegation (redelegate)"
        echo -e "   ${GREEN}2.${NC} Send               ${GREEN}6.${NC} Cancel a defusion"
        echo -e "   ${GREEN}3.${NC} Delegate           ${GREEN}7.${NC} Consolidate funds into one address"
        echo -e "   ${GREEN}4.${NC} Undelegate         ${GREEN}8.${NC} Look up another player"
        echo -e "   ${GREEN}0.${NC} Back"
        echo ""
        read -r -p "Select an option: " opt
        case "$opt" in
            1) continue ;;
            2) read -r -p "Recipient (address or player id): " a
               read -r -p "Amount (e.g. 2.5alpha, 2500000ualpha, all): " b
               sx_wallet_send "$a" "$b" ;;
            3) read -r -p "Validator (reactor id 3-N, player id, guild id 0-N, moniker or valoper): " a
               read -r -p "Amount (e.g. 10alpha, all): " b
               sx_wallet_delegate "$a" "$b" ;;
            4) read -r -p "Validator to undelegate from: " a
               read -r -p "Amount (e.g. 10alpha, all): " b
               sx_wallet_undelegate "$a" "$b" ;;
            5) read -r -p "Move from validator: " a
               read -r -p "Move to validator: " b
               read -r -p "Amount (e.g. 10alpha, all): " c
               sx_wallet_redelegate "$a" "$b" "$c" ;;
            6) read -r -p "Defusion # to cancel: " a
               read -r -p "Amount (blank = all of it): " b
               sx_wallet_cancel_defuse "$a" "$b" ;;
            7) read -r -p "Consolidate into (vault / primary / address): " a
               read -r -p "Token (alpha / all / denom) [alpha]: " b
               sx_wallet_consolidate "$a" "${b:-ualpha}" ;;
            8) read -r -p "Player id or address: " who; continue ;;
            0) return 0 ;;
            *) sx_err "invalid option" ;;
        esac
        read -r -p "Press Enter to continue..." _
    done
}
