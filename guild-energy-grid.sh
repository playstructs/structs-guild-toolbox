#!/bin/bash
#
# Energy grid: the guild's entry substation and the energy providers owned by
# you or by the guild.

function _grid_providers() {
    # Providers owned by this player or this guild, one JSON object per line
    sx_q_all Provider structs provider-all \
        | jq -c --arg p "$PLAYER_ID" --arg g "$GUILD_ID" 'select(.owner == $p or .owner == $g)'
}

function energy_grid_menu() {
    print_header
    GUILD_JSON=$(sx_q structs guild "$GUILD_ID")
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")
    SUBSTATION_ID=$(echo "$GUILD_JSON" | jq -r '.Guild.entrySubstationId // empty')

    echo -e "${CYAN}=== ENERGY GRID MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})   ${YELLOW}Player:${NC} ${PLAYER_ID}"
    echo ""

    SUBSTATION_JSON=$(sx_q structs substation "$SUBSTATION_ID")
    if [ -n "$SUBSTATION_JSON" ]; then
        echo -e "${CYAN}=== ENTRY SUBSTATION ${SUBSTATION_ID} ===${NC}"
        echo -e "${YELLOW}Owner:${NC} $(echo "$SUBSTATION_JSON" | jq -r '.Substation.owner')"
        echo -e "${YELLOW}Load / capacity:${NC} $(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.load // 0') / $(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.capacity // 0')"
        echo -e "${YELLOW}Connections:${NC} $(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCount // 0') / $(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCapacity // 0')"
    else
        echo -e "${RED}No entry substation found for this guild.${NC}"
    fi
    echo ""

    PROVIDERS=$(_grid_providers)
    echo -e "${CYAN}=== YOUR PROVIDERS ===${NC}"
    if [ -z "$PROVIDERS" ]; then
        echo "  (none)"
    else
        printf "  %-8s %-8s %-8s %-18s %-16s %s\n" "ID" "OWNER" "SUBST" "RATE" "CAPACITY" "DURATION"
        echo "$PROVIDERS" | jq -r '"\(.id)\t\(.owner)\t\(.substationId)\t\(.rate.amount)\(.rate.denom)\t\(.capacityMinimum)-\(.capacityMaximum)\t\(.durationMinimum)-\(.durationMaximum)"' \
            | while IFS=$'\t' read -r a b c d e f; do printf "  %-8s %-8s %-8s %-18s %-16s %s\n" "$a" "$b" "$c" "$d" "$e" "$f"; done
    fi
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Create provider"
    echo -e "${GREEN}3.${NC} View provider (agreements, earnings)"
    echo -e "${GREEN}4.${NC} Withdraw provider earnings"
    echo -e "${GREEN}5.${NC} Change provider access policy"
    echo -e "${GREEN}6.${NC} Delete provider (cancels all agreements)"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " ENERGY_OPTION

    case $ENERGY_OPTION in
        1) energy_grid_menu ;;
        2) create_provider ;;
        3) view_provider_details ;;
        4) withdraw_balance ;;
        5) update_access_policy ;;
        6) delete_provider ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            energy_grid_menu
            ;;
    esac
}

function _grid_back() { press_enter_to_continue; energy_grid_menu; }

function _select_access_policy() {
    echo -e "${CYAN}Access policy:${NC}"
    echo -e "${GREEN}1.${NC} Public (open-market)"
    echo -e "${GREEN}2.${NC} Guild only (guild-market)"
    echo -e "${GREEN}3.${NC} Closed (closed-market)"
    read -p "Select (1-3): " _ap
    case $_ap in
        1) ACCESS_POLICY="open-market" ;;
        2) ACCESS_POLICY="guild-market" ;;
        3) ACCESS_POLICY="closed-market" ;;
        *) ACCESS_POLICY="" ;;
    esac
}

function _read_uint() {
    local prompt="$1" var="$2" v
    read -p "$prompt" v
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then echo -e "${RED}Not a whole number.${NC}"; return 1; fi
    eval "$var=\$v"
}

function create_provider() {
    print_header
    echo -e "${CYAN}=== CREATE PROVIDER ===${NC}"
    SUBSTATION_ID=$(sx_q structs guild "$GUILD_ID" | jq -r '.Guild.entrySubstationId // empty')
    read -p "Substation ID [${SUBSTATION_ID}]: " _s
    SUBSTATION_ID="${_s:-$SUBSTATION_ID}"
    if [ -z "$(sx_q structs substation "$SUBSTATION_ID" | jq -r '.Substation.id // empty')" ]; then
        echo -e "${RED}Substation ${SUBSTATION_ID} not found.${NC}"; _grid_back; return
    fi
    echo -e "Owner: ${GREEN}1.${NC} me (${PLAYER_ID})  ${GREEN}2.${NC} the guild (${GUILD_ID})"
    read -p "Select (1-2) [1]: " _o
    OWNER_FLAG=()
    [ "$_o" = "2" ] && OWNER_FLAG=(--owner-id "$GUILD_ID")

    read -p "Rate per unit (e.g. 100ualpha or 2390uguild.${GUILD_ID}): " RATE
    _select_access_policy
    [ -z "$ACCESS_POLICY" ] && { echo -e "${RED}Invalid access policy.${NC}"; _grid_back; return; }
    echo -e "${DIM}Penalties are decimals between 0 and 1 (e.g. 0.05)${NC}"
    read -p "Provider cancellation penalty: " PROVIDER_PENALTY
    read -p "Consumer cancellation penalty: " CONSUMER_PENALTY
    _read_uint "Minimum capacity: " CAPACITY_MIN || { _grid_back; return; }
    _read_uint "Maximum capacity: " CAPACITY_MAX || { _grid_back; return; }
    _read_uint "Minimum duration (blocks): " DURATION_MIN || { _grid_back; return; }
    _read_uint "Maximum duration (blocks): " DURATION_MAX || { _grid_back; return; }
    if [ "$CAPACITY_MAX" -lt "$CAPACITY_MIN" ] || [ "$DURATION_MAX" -lt "$DURATION_MIN" ]; then
        echo -e "${RED}Maximums must be at least the minimums.${NC}"; _grid_back; return
    fi

    echo ""
    echo -e "${YELLOW}Provider:${NC} substation ${SUBSTATION_ID}, rate ${RATE}, ${ACCESS_POLICY}"
    echo -e "  penalties provider ${PROVIDER_PENALTY} / consumer ${CONSUMER_PENALTY}"
    echo -e "  capacity ${CAPACITY_MIN}-${CAPACITY_MAX}, duration ${DURATION_MIN}-${DURATION_MAX} blocks"
    sx_tx_reset
    sx_tx_add structs provider-create "$SUBSTATION_ID" "$RATE" "$ACCESS_POLICY" "$PROVIDER_PENALTY" "$CONSUMER_PENALTY" \
        "$CAPACITY_MIN" "$CAPACITY_MAX" "$DURATION_MIN" "$DURATION_MAX" "${OWNER_FLAG[@]+"${OWNER_FLAG[@]}"}"
    sx_confirm "Create this provider?" && sx_tx_run
    _grid_back
}

function view_provider_details() {
    print_header
    read -p "Provider ID: " CURRENT_PROVIDER_ID
    local p
    p=$(sx_q structs provider "$CURRENT_PROVIDER_ID")
    if [ -z "$(echo "$p" | jq -r '.Provider.id // empty')" ]; then
        echo -e "${RED}Provider ${CURRENT_PROVIDER_ID} not found.${NC}"; _grid_back; return
    fi
    echo -e "${CYAN}=== PROVIDER ${CURRENT_PROVIDER_ID} ===${NC}"
    echo "$p" | jq -r '.Provider | to_entries[] | "  \(.key): \(.value | if type == "object" then "\(.amount)\(.denom)" else tostring end)"'
    local earn
    earn=$(sx_q structs provider-earnings-address "$CURRENT_PROVIDER_ID" | jq -r '.internalAddressAssociation[0].address // empty')
    if [ -n "$earn" ]; then
        echo ""
        echo -e "${CYAN}Earnings${NC} (${earn}):"
        sx_q bank balances "$earn" | jq -r '.balances[]? | "  \(.amount) \(.denom)"'
    fi
    echo ""
    echo -e "${CYAN}Agreements:${NC}"
    sx_q_all Agreement structs agreement-all-by-provider "$CURRENT_PROVIDER_ID" \
        | jq -r '"  \(.id)  owner \(.owner)  capacity \(.capacity)  blocks \(.startBlock)-\(.endBlock)"'
    _grid_back
}

function withdraw_balance() {
    print_header
    echo -e "${CYAN}=== WITHDRAW PROVIDER EARNINGS ===${NC}"
    read -p "Provider ID: " CURRENT_PROVIDER_ID
    local vault
    vault=$(sx_vault_of "$PLAYER_ID")
    read -p "Destination address [your player vault ${vault}]: " DEST
    DEST="${DEST:-$vault}"
    sx_tx_reset
    sx_tx_add structs provider-withdraw-balance "$CURRENT_PROVIDER_ID" "$DEST"
    sx_confirm "Withdraw ${CURRENT_PROVIDER_ID} earnings to ${DEST}?" && sx_tx_run
    _grid_back
}

function update_access_policy() {
    print_header
    echo -e "${CYAN}=== CHANGE ACCESS POLICY ===${NC}"
    read -p "Provider ID: " CURRENT_PROVIDER_ID
    _select_access_policy
    [ -z "$ACCESS_POLICY" ] && { echo -e "${RED}Invalid access policy.${NC}"; _grid_back; return; }
    sx_tx_reset
    sx_tx_add structs provider-update-access-policy "$CURRENT_PROVIDER_ID" "$ACCESS_POLICY"
    sx_confirm "Set ${CURRENT_PROVIDER_ID} to ${ACCESS_POLICY}?" && sx_tx_run
    _grid_back
}

function delete_provider() {
    print_header
    echo -e "${CYAN}=== DELETE PROVIDER ===${NC}"
    read -p "Provider ID: " CURRENT_PROVIDER_ID
    echo -e "${RED}This cancels every agreement on ${CURRENT_PROVIDER_ID}.${NC}"
    sx_tx_reset
    sx_tx_add structs provider-delete "$CURRENT_PROVIDER_ID"
    sx_confirm "Delete provider ${CURRENT_PROVIDER_ID}?" && sx_tx_run
    _grid_back
}
