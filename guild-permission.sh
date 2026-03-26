#!/bin/bash

# Structs permission flags: 24 bits (0–23), uint64. See:
# https://structs.ai/knowledge/mechanics/permissions.html
PERM_ALL=16777215

PERMISSION_FLAGS=0

PERM_BIT_NAMES=(
    PermPlay
    PermAdmin
    PermUpdate
    PermDelete
    PermTokenTransfer
    PermTokenInfuse
    PermTokenMigrate
    PermTokenDefuse
    PermSourceAllocation
    PermGuildMembership
    PermSubstationConnection
    PermAllocationConnection
    PermGuildTokenBurn
    PermGuildTokenMint
    PermGuildEndpointUpdate
    PermGuildJoinConstraintsUpdate
    PermGuildSubstationUpdate
    PermProviderWithdraw
    PermProviderOpen
    PermReactorGuildCreate
    PermHashBuild
    PermHashMine
    PermHashRefine
    PermHashRaid
)

function _perm_bit_value() {
    local b="$1"
    echo $((1 << b))
}

function _permission_records_from_json() {
    local json="$1"
    echo "$json" | jq -c '(.permissionRecords // .permission_records // empty)' 2>/dev/null
}

function permissions_menu() {
    print_header

    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    echo -e "${CYAN}=== PERMISSIONS MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo -e "${YELLOW}Player ID:${NC} ${PLAYER_ID}"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Proxy Join (Add Member)"
    echo -e "${GREEN}2.${NC} Object permissions (grant / revoke / set)"
    echo -e "${GREEN}3.${NC} Address permissions (grant / revoke / set)"
    echo -e "${GREEN}4.${NC} Guild rank permissions (set / revoke)"
    echo -e "${GREEN}5.${NC} Update player guild rank"
    echo -e "${GREEN}6.${NC} Queries (by object, player, id, guild rank, all)"
    echo -e "${GREEN}7.${NC} Permission reference (help)"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " PERM_OPTION

    case $PERM_OPTION in
        1) proxy_join ;;
        2) object_permissions_submenu ;;
        3) address_permissions_submenu ;;
        4) guild_rank_permissions_submenu ;;
        5) update_player_guild_rank ;;
        6) queries_permissions_submenu ;;
        7) permissions_help ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            permissions_menu
            ;;
    esac
}

function object_permissions_submenu() {
    print_header
    echo -e "${CYAN}=== OBJECT PERMISSIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Grant on object"
    echo -e "${GREEN}2.${NC} Revoke on object"
    echo -e "${GREEN}3.${NC} Set on object (replaces entire mask — destructive)"
    echo -e "${GREEN}0.${NC} Back"
    echo ""
    read -p "Select: " _opt
    case $_opt in
        1) grant_permission ;;
        2) revoke_permission ;;
        3) set_permission_on_object ;;
        0) permissions_menu ;;
        *) echo -e "${RED}Invalid.${NC}"; press_enter_to_continue; object_permissions_submenu ;;
    esac
}

function address_permissions_submenu() {
    print_header
    echo -e "${CYAN}=== ADDRESS PERMISSIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Grant on address"
    echo -e "${GREEN}2.${NC} Revoke on address"
    echo -e "${GREEN}3.${NC} Set on address (replaces entire mask)"
    echo -e "${GREEN}0.${NC} Back"
    echo ""
    read -p "Select: " _opt
    case $_opt in
        1) grant_permission_address ;;
        2) revoke_permission_address ;;
        3) set_permission_address ;;
        0) permissions_menu ;;
        *) echo -e "${RED}Invalid.${NC}"; press_enter_to_continue; address_permissions_submenu ;;
    esac
}

function guild_rank_permissions_submenu() {
    print_header
    echo -e "${CYAN}=== GUILD RANK PERMISSIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Set rank threshold for permission bits"
    echo -e "${GREEN}2.${NC} Revoke rank permission bits"
    echo -e "${GREEN}0.${NC} Back"
    echo ""
    read -p "Select: " _opt
    case $_opt in
        1) guild_rank_set_tx ;;
        2) guild_rank_revoke_tx ;;
        0) permissions_menu ;;
        *) echo -e "${RED}Invalid.${NC}"; press_enter_to_continue; guild_rank_permissions_submenu ;;
    esac
}

function queries_permissions_submenu() {
    print_header
    echo -e "${CYAN}=== PERMISSION QUERIES ===${NC}"
    echo -e "${GREEN}1.${NC} By object (all records on object)"
    echo -e "${GREEN}2.${NC} By player (all records for player)"
    echo -e "${GREEN}3.${NC} Single record by permission ID"
    echo -e "${GREEN}4.${NC} Guild rank by object (all guilds)"
    echo -e "${GREEN}5.${NC} Guild rank by object + guild"
    echo -e "${GREEN}6.${NC} Permission-all (entire chain — can be large)"
    echo -e "${GREEN}0.${NC} Back"
    echo ""
    read -p "Select: " _opt
    case $_opt in
        1) view_permissions ;;
        2) view_permissions_by_player ;;
        3) view_permission_by_id ;;
        4) view_guild_rank_by_object ;;
        5) view_guild_rank_by_object_guild ;;
        6) view_permission_all ;;
        0) permissions_menu ;;
        *) echo -e "${RED}Invalid.${NC}"; press_enter_to_continue; queries_permissions_submenu ;;
    esac
}

function _apply_preset_mask() {
    local mode="$1"
    local preset_val="$2"
    local current="$3"
    if [[ "$mode" == "replace" ]]; then
        echo "$preset_val"
    else
        echo $((current | preset_val))
    fi
}

function select_preset_composite() {
    print_header
    echo -e "${CYAN}=== COMPOSITE PRESET ===${NC}"
    echo "Choose preset:"
    echo -e "${GREEN}1.${NC} PermAssetsAll (240)"
    echo -e "${GREEN}2.${NC} PermHashAll (15728640)"
    echo -e "${GREEN}3.${NC} PermAgreementAll (14)"
    echo -e "${GREEN}4.${NC} PermProviderAll (393230)"
    echo -e "${GREEN}5.${NC} PermGuildAll (315910)"
    echo -e "${GREEN}6.${NC} PermSubstationAll (1294)"
    echo -e "${GREEN}7.${NC} PermReactorAll (524558)"
    echo -e "${GREEN}8.${NC} PermAllocationAll (2062)"
    echo -e "${GREEN}9.${NC} PermAll / PermPlayerAll (${PERM_ALL})"
    echo -e "${GREEN}0.${NC} Cancel"
    echo ""
    read -p "Preset: " p
    case $p in
        1) PRESET_CHOICE_VAL=240 ;;
        2) PRESET_CHOICE_VAL=15728640 ;;
        3) PRESET_CHOICE_VAL=14 ;;
        4) PRESET_CHOICE_VAL=393230 ;;
        5) PRESET_CHOICE_VAL=315910 ;;
        6) PRESET_CHOICE_VAL=1294 ;;
        7) PRESET_CHOICE_VAL=524558 ;;
        8) PRESET_CHOICE_VAL=2062 ;;
        9) PRESET_CHOICE_VAL=${PERM_ALL} ;;
        0) PRESET_CHOICE_VAL="" ;;
        *) PRESET_CHOICE_VAL="" ;;
    esac
}

function select_permissions() {
    local current_permissions=0
    local done=false

    while [ "$done" = false ]; do
        clear
        echo -e "${CYAN}=== SELECT PERMISSION MASK (uint64) ===${NC}"
        echo ""
        echo "Current value: ${current_permissions}"
        echo "Decoded: $(display_permissions "${current_permissions}")"
        echo ""
        echo -e "${YELLOW}Per-bit toggles:${NC} enter bit index ${GREEN}0${NC}-${GREEN}23${NC} to XOR that flag into the mask."
        echo ""
        local b
        for b in $(seq 0 23); do
            local pv
            pv=$(_perm_bit_value "$b")
            local on=" "
            if (( (current_permissions & pv) != 0 )); then on="X"; fi
            printf "  [%s] %2d  %-28s  (value %s)\n" "$on" "$b" "${PERM_BIT_NAMES[$b]}" "$pv"
        done
        echo ""
        echo -e "${GREEN}a${NC} Add composite to mask (bitwise OR)"
        echo -e "${GREEN}r${NC} Replace mask with composite preset"
        echo -e "${GREEN}u${NC} Enter raw uint64 decimal"
        echo -e "${GREEN}c${NC} Clear mask (0)"
        echo -e "${GREEN}f${NC} Full mask (${PERM_ALL})"
        echo -e "${GREEN}0${NC} Done"
        echo ""

        read -p "Choice: " PERM_OPTION

        case $PERM_OPTION in
            [0-9]|[12][0-9]|2[0-3])
                if [[ "$PERM_OPTION" =~ ^[0-9]+$ ]] && [ "$PERM_OPTION" -ge 0 ] && [ "$PERM_OPTION" -le 23 ]; then
                    local vv
                    vv=$(_perm_bit_value "$PERM_OPTION")
                    current_permissions=$((current_permissions ^ vv))
                else
                    echo "Invalid bit index."
                    sleep 1
                fi
                ;;
            a|A)
                select_preset_composite
                if [[ -n "${PRESET_CHOICE_VAL}" ]]; then
                    current_permissions=$(_apply_preset_mask merge "$PRESET_CHOICE_VAL" "$current_permissions")
                fi
                ;;
            r|R)
                select_preset_composite
                if [[ -n "${PRESET_CHOICE_VAL}" ]]; then
                    current_permissions=$(_apply_preset_mask replace "$PRESET_CHOICE_VAL" "$current_permissions")
                fi
                ;;
            u|U)
                read -p "Enter uint64 (decimal): " rawp
                if [[ "$rawp" =~ ^[0-9]+$ ]]; then
                    current_permissions=$rawp
                else
                    echo "Invalid number."
                    sleep 1
                fi
                ;;
            c|C) current_permissions=0 ;;
            f|F) current_permissions=${PERM_ALL} ;;
            0) done=true ;;
            *)
                echo "Invalid option."
                sleep 1
                ;;
        esac
    done

    PERMISSION_FLAGS="${current_permissions}"
}

function display_permissions() {
    local permission_value="$1"
    local permission_string=""
    local first=true

    if [[ ! "$permission_value" =~ ^[0-9]+$ ]]; then
        echo "Unknown"
        return
    fi

    if [ "$permission_value" -eq 0 ]; then
        echo "None (Permissionless)"
        return
    fi

    if [ "$permission_value" -eq "${PERM_ALL}" ]; then
        echo "PermAll / PermPlayerAll (all 24 bits)"
        return
    fi

    local i
    for i in $(seq 0 23); do
        local pv
        pv=$(_perm_bit_value "$i")
        if (( (permission_value & pv) != 0 )); then
            if [ "$first" = true ]; then
                permission_string="${PERM_BIT_NAMES[$i]}"
                first=false
            else
                permission_string="${permission_string}, ${PERM_BIT_NAMES[$i]}"
            fi
        fi
    done

    if [ "$first" = true ]; then
        echo "(unrecognized bits in mask)"
    else
        echo "$permission_string"
    fi
}

function permissions_help() {
    print_header
    echo -e "${CYAN}=== PERMISSION REFERENCE (summary) ===${NC}"
    echo ""
    echo "Layers: address permissions, object permissions, guild rank register (per objectId + guildId)."
    echo "Permission meta-txs: caller must already hold the same flags being granted/revoked/set."
    echo ""
    echo -e "${YELLOW}Multi-check examples:${NC}"
    echo "  GuildCreate: PermReactorGuildCreate on reactor + PermSubstationConnection on substation if set."
    echo "  GuildUpdateEntrySubstationId: PermGuildSubstationUpdate on guild + PermSubstationConnection on target substation."
    echo "  SubstationPlayerConnect: PermSubstationConnection on substation AND on player."
    echo "  SubstationPlayerDisconnect: PermSubstationConnection on player OR substation."
    echo "  GuildMembershipJoinProxy: PermGuildMembership on guild + PermSubstationConnection if substation override."
    echo ""
    echo -e "${YELLOW}Guild membership:${NC} PermGuildMembership (512); bypass level (permissioned / member / closed) changes checks."
    echo ""
    echo -e "${YELLOW}Structs:${NC} CanBePlayedBy uses PermPlay on struct owner (player). CanBeHashedBy uses PermHashAll on struct."
    echo "  PlanetRaidComplete: PermHashRaid on fleet owner (player), not PermHashAll on struct."
    echo ""
    echo -e "${YELLOW}player-update-guild-rank:${NC} PermAdmin (2) on guild, or rank-based fallback (actor strictly better than target rank)."
    echo ""
    echo -e "${YELLOW}Guild rank threshold:${NC} rank is worst-allowed; lower player rank number = more privilege. Slot 0 = bit unset."
    echo ""
    press_enter_to_continue
    permissions_menu
}

function proxy_join() {
    print_header
    echo -e "${CYAN}=== PROXY JOIN (ADD MEMBER) ===${NC}"
    echo ""

    read -p "Enter Player Address to add: " TARGET_PLAYER_ADDRESS

    if [[ -z "$TARGET_PLAYER_ADDRESS" ]]; then
        echo -e "${RED}Player Address cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Enter Player Pubkey to add: " TARGET_PLAYER_PUBKEY

    if [[ -z "$TARGET_PLAYER_PUBKEY" ]]; then
        echo -e "${RED}Player Pubkey cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Enter Player Proof Signature to add: " TARGET_PLAYER_SIGNATURE

    if [[ -z "$TARGET_PLAYER_SIGNATURE" ]]; then
        echo -e "${RED}Player Signature cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Adding player ${TARGET_PLAYER_ADDRESS} via guild proxy join...${NC}"
    structsd ${PARAMS_TX} tx structs guild-membership-join-proxy ${TARGET_PLAYER_ADDRESS} ${TARGET_PLAYER_PUBKEY} ${TARGET_PLAYER_SIGNATURE} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function grant_permission() {
    print_header
    echo -e "${CYAN}=== GRANT PERMISSION ON OBJECT ===${NC}"
    echo ""

    read -p "Enter Object ID to grant permission on: " TARGET_OBJECT_ID

    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Enter Player ID to grant permission to: " TARGET_PLAYER_ID

    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Select permission bits to grant (OR into existing record):${NC}"
    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Granting ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) to player ${TARGET_PLAYER_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-grant-on-object ${TARGET_OBJECT_ID} ${TARGET_PLAYER_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function set_permission_on_object() {
    print_header
    echo -e "${CYAN}=== SET PERMISSION ON OBJECT (destructive) ===${NC}"
    echo -e "${RED}This replaces the entire permission value; omitted bits are removed.${NC}"
    echo ""

    read -p "Type YES to continue: " _confirm
    if [[ "$_confirm" != "YES" ]]; then
        permissions_menu
        return
    fi

    read -p "Enter Object ID: " TARGET_OBJECT_ID
    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Enter Player ID: " TARGET_PLAYER_ID
    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Setting mask to ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) for ${TARGET_PLAYER_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-set-on-object ${TARGET_OBJECT_ID} ${TARGET_PLAYER_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function revoke_permission() {
    print_header
    echo -e "${CYAN}=== REVOKE PERMISSION ON OBJECT ===${NC}"
    echo ""

    read -p "Enter Object ID to revoke permission on: " TARGET_OBJECT_ID

    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Enter Player ID to revoke permission from: " TARGET_PLAYER_ID

    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Select bits to revoke (removed via AND NOT):${NC}"
    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Revoking ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) from player ${TARGET_PLAYER_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-revoke-on-object ${TARGET_OBJECT_ID} ${TARGET_PLAYER_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function grant_permission_address() {
    print_header
    echo -e "${CYAN}=== GRANT PERMISSION ON ADDRESS ===${NC}"
    echo ""

    read -p "Enter cosmos address: " TARGET_ADDRESS
    if [[ -z "$TARGET_ADDRESS" ]]; then
        echo -e "${RED}Address cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Granting ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) on address ${TARGET_ADDRESS}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-grant-on-address ${TARGET_ADDRESS} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function revoke_permission_address() {
    print_header
    echo -e "${CYAN}=== REVOKE PERMISSION ON ADDRESS ===${NC}"
    echo ""

    read -p "Enter cosmos address: " TARGET_ADDRESS
    if [[ -z "$TARGET_ADDRESS" ]]; then
        echo -e "${RED}Address cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Revoking ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) from address ${TARGET_ADDRESS}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-revoke-on-address ${TARGET_ADDRESS} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function set_permission_address() {
    print_header
    echo -e "${CYAN}=== SET PERMISSION ON ADDRESS ===${NC}"
    echo -e "${RED}Replaces entire address permission mask.${NC}"
    read -p "Type YES to continue: " _confirm
    if [[ "$_confirm" != "YES" ]]; then
        permissions_menu
        return
    fi

    read -p "Enter cosmos address: " TARGET_ADDRESS
    if [[ -z "$TARGET_ADDRESS" ]]; then
        echo -e "${RED}Address cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Setting ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) on ${TARGET_ADDRESS}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-set-on-address ${TARGET_ADDRESS} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function guild_rank_set_tx() {
    print_header
    echo -e "${CYAN}=== GUILD RANK PERMISSION SET ===${NC}"
    echo ""

    read -p "Object ID (e.g. guild or substation): " TARGET_OBJECT_ID
    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Guild ID (members receiving rank-based access): " TARGET_GUILD_ID
    if [[ -z "$TARGET_GUILD_ID" ]]; then
        echo -e "${RED}Guild ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Select permission bitmask (decomposed per bit on chain):${NC}"
    select_permissions
    local perm_mask=$PERMISSION_FLAGS

    read -p "Worst-allowed guild rank (>= 1, higher number = less privileged): " RANK_VAL
    if [[ ! "$RANK_VAL" =~ ^[0-9]+$ ]] || [ "$RANK_VAL" -lt 1 ]; then
        echo -e "${RED}Invalid rank.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PERMISSION_READABLE=$(display_permissions "$perm_mask")
    echo -e "${YELLOW}Setting ${PERMISSION_READABLE} (${perm_mask}) at max rank ${RANK_VAL} for guild ${TARGET_GUILD_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-guild-rank-set ${TARGET_OBJECT_ID} ${TARGET_GUILD_ID} ${perm_mask} ${RANK_VAL} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function guild_rank_revoke_tx() {
    print_header
    echo -e "${CYAN}=== GUILD RANK PERMISSION REVOKE ===${NC}"
    echo ""

    read -p "Object ID: " TARGET_OBJECT_ID
    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Guild ID: " TARGET_GUILD_ID
    if [[ -z "$TARGET_GUILD_ID" ]]; then
        echo -e "${RED}Guild ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Select bits to clear from rank register:${NC}"
    select_permissions
    PERMISSION_READABLE=$(display_permissions "$PERMISSION_FLAGS")

    echo -e "${YELLOW}Revoking ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) for guild ${TARGET_GUILD_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-guild-rank-revoke ${TARGET_OBJECT_ID} ${TARGET_GUILD_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function update_player_guild_rank() {
    print_header
    echo -e "${CYAN}=== UPDATE PLAYER GUILD RANK ===${NC}"
    echo ""

    read -p "Target player ID: " TARGET_PLAYER_ID
    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "New guild rank (numeric): " GUILD_RANK
    if [[ ! "$GUILD_RANK" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid rank.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Updating guild rank for ${TARGET_PLAYER_ID} to ${GUILD_RANK}...${NC}"
    structsd ${PARAMS_TX} tx structs player-update-guild-rank -- ${TARGET_PLAYER_ID} ${GUILD_RANK} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME
    echo -e "${GREEN}Transaction submitted.${NC}"
    press_enter_to_continue
    permissions_menu
}

function view_permissions() {
    print_header
    echo -e "${CYAN}=== PERMISSIONS BY OBJECT ===${NC}"
    echo ""

    read -p "Enter Object ID: " TARGET_OBJECT_ID

    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PERMISSIONS_JSON=$(structsd ${PARAMS_QUERY} query structs permission-by-object ${TARGET_OBJECT_ID})
    PERMISSIONS=$(_permission_records_from_json "$PERMISSIONS_JSON")

    if [[ -z "$PERMISSIONS" || "$PERMISSIONS" == "null" ]]; then
        echo -e "${YELLOW}No permission records found (or query failed).${NC}"
        echo "$PERMISSIONS_JSON" | jq . 2>/dev/null || echo "$PERMISSIONS_JSON"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${CYAN}Records for object ${TARGET_OBJECT_ID}${NC}"
    echo ""

    printf "%-42s | %-10s | %s\n" "permissionId" "flags" "decoded"
    echo "--------------------------------------------------------------------------------------------------------"

    PERMISSION_COUNT=$(echo "${PERMISSIONS}" | jq length)
    local p
    for (( p=0; p<PERMISSION_COUNT; p++ )); do
        PERMISSION_ID=$(echo "$PERMISSIONS" | jq -r ".[${p}].permissionId")
        local pflags
        pflags=$(echo "$PERMISSIONS" | jq -r ".[${p}].value")
        PERMISSION_READABLE=$(display_permissions "$pflags")

        printf "%-42s | %-10s | %s\n" "$PERMISSION_ID" "$pflags" "$PERMISSION_READABLE"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}

function view_permissions_by_player() {
    print_header
    echo -e "${CYAN}=== PERMISSIONS BY PLAYER ===${NC}"
    echo ""

    read -p "Enter Player ID: " TARGET_PLAYER_ID
    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PERMISSIONS_JSON=$(structsd ${PARAMS_QUERY} query structs permission-by-player ${TARGET_PLAYER_ID})
    PERMISSIONS=$(_permission_records_from_json "$PERMISSIONS_JSON")

    if [[ -z "$PERMISSIONS" || "$PERMISSIONS" == "null" ]]; then
        echo -e "${YELLOW}No permission records found.${NC}"
        echo "$PERMISSIONS_JSON" | jq . 2>/dev/null || echo "$PERMISSIONS_JSON"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${CYAN}Records for player ${TARGET_PLAYER_ID}${NC}"
    echo ""
    printf "%-42s | %-10s | %s\n" "permissionId" "flags" "decoded"
    echo "--------------------------------------------------------------------------------------------------------"

    PERMISSION_COUNT=$(echo "${PERMISSIONS}" | jq length)
    local p
    for (( p=0; p<PERMISSION_COUNT; p++ )); do
        PERMISSION_ID=$(echo "$PERMISSIONS" | jq -r ".[${p}].permissionId")
        local pflags
        pflags=$(echo "$PERMISSIONS" | jq -r ".[${p}].value")
        PERMISSION_READABLE=$(display_permissions "$pflags")
        printf "%-42s | %-10s | %s\n" "$PERMISSION_ID" "$pflags" "$PERMISSION_READABLE"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}

function view_permission_by_id() {
    print_header
    echo -e "${CYAN}=== PERMISSION BY ID ===${NC}"
    echo "Examples: object perms: 4-1@1-2   address perms: 8-cosmos1...@0"
    echo ""

    read -p "permissionId: " PID
    if [[ -z "$PID" ]]; then
        echo -e "${RED}permissionId required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    local out
    out=$(structsd ${PARAMS_QUERY} query structs permission "${PID}")
    local val
    val=$(echo "$out" | jq -r '.permissionRecord.value // .permission_record.value // empty' 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo -e "${YELLOW}No record or query error.${NC}"
        echo "$out" | jq . 2>/dev/null || echo "$out"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo "value: $val"
    echo "decoded: $(display_permissions "$val")"
    echo ""
    echo "$out" | jq . 2>/dev/null
    press_enter_to_continue
    permissions_menu
}

function _guild_rank_records_from_json() {
    local json="$1"
    echo "$json" | jq -c '(.guild_rank_permission_records // .guildRankPermissionRecords // empty)' 2>/dev/null
}

function view_guild_rank_by_object() {
    print_header
    echo -e "${CYAN}=== GUILD RANK PERMISSIONS BY OBJECT ===${NC}"
    echo ""

    read -p "Object ID: " TARGET_OBJECT_ID
    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    local json recs
    json=$(structsd ${PARAMS_QUERY} query structs guild-rank-permission-by-object ${TARGET_OBJECT_ID})
    recs=$(_guild_rank_records_from_json "$json")

    if [[ -z "$recs" || "$recs" == "null" ]]; then
        echo -e "${YELLOW}No records or unsupported response.${NC}"
        echo "$json" | jq . 2>/dev/null || echo "$json"
        press_enter_to_continue
        permissions_menu
        return
    fi

    printf "%-12s | %-12s | %-12s | %-12s | %s\n" "objectId" "guildId" "bit value" "rank" "perm name"
    echo "------------------------------------------------------------------------------------------------------------"
    local n i
    n=$(echo "$recs" | jq length)
    for (( i=0; i<n; i++ )); do
        local oid gid pv rk
        oid=$(echo "$recs" | jq -r ".[$i].objectId // .[$i].object_id")
        gid=$(echo "$recs" | jq -r ".[$i].guildId // .[$i].guild_id")
        pv=$(echo "$recs" | jq -r ".[$i].permissions")
        rk=$(echo "$recs" | jq -r ".[$i].rank")
        local pname
        pname=$(display_permissions "$pv")
        printf "%-12s | %-12s | %-12s | %-12s | %s\n" "$oid" "$gid" "$pv" "$rk" "$pname"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}

function view_guild_rank_by_object_guild() {
    print_header
    echo -e "${CYAN}=== GUILD RANK PERMISSIONS (OBJECT + GUILD) ===${NC}"
    echo ""

    read -p "Object ID: " TARGET_OBJECT_ID
    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    read -p "Guild ID: " TARGET_GUILD_ID
    if [[ -z "$TARGET_GUILD_ID" ]]; then
        echo -e "${RED}Guild ID required.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    local json recs
    json=$(structsd ${PARAMS_QUERY} query structs guild-rank-permission-by-object-and-guild ${TARGET_OBJECT_ID} ${TARGET_GUILD_ID})
    recs=$(_guild_rank_records_from_json "$json")

    if [[ -z "$recs" || "$recs" == "null" ]]; then
        echo -e "${YELLOW}No records or unsupported response.${NC}"
        echo "$json" | jq . 2>/dev/null || echo "$json"
        press_enter_to_continue
        permissions_menu
        return
    fi

    printf "%-12s | %-12s | %-12s | %-12s | %s\n" "objectId" "guildId" "bit value" "rank" "perm name"
    echo "------------------------------------------------------------------------------------------------------------"
    local n i
    n=$(echo "$recs" | jq length)
    for (( i=0; i<n; i++ )); do
        local oid gid pv rk
        oid=$(echo "$recs" | jq -r ".[$i].objectId // .[$i].object_id")
        gid=$(echo "$recs" | jq -r ".[$i].guildId // .[$i].guild_id")
        pv=$(echo "$recs" | jq -r ".[$i].permissions")
        rk=$(echo "$recs" | jq -r ".[$i].rank")
        local pname
        pname=$(display_permissions "$pv")
        printf "%-12s | %-12s | %-12s | %-12s | %s\n" "$oid" "$gid" "$pv" "$rk" "$pname"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}

function view_permission_all() {
    print_header
    echo -e "${CYAN}=== PERMISSION-ALL ===${NC}"
    echo -e "${RED}This can return a very large JSON payload.${NC}"
    read -p "Continue? [y/N]: " _go
    if [[ "$_go" != "y" && "$_go" != "Y" ]]; then
        permissions_menu
        return
    fi

    PERMISSIONS_JSON=$(structsd ${PARAMS_QUERY} query structs permission-all)
    PERMISSIONS=$(_permission_records_from_json "$PERMISSIONS_JSON")

    if [[ -z "$PERMISSIONS" || "$PERMISSIONS" == "null" ]]; then
        echo -e "${YELLOW}No permissionRecords in response; dumping raw JSON.${NC}"
        echo "$PERMISSIONS_JSON" | jq . 2>/dev/null || echo "$PERMISSIONS_JSON"
        press_enter_to_continue
        permissions_menu
        return
    fi

    PERMISSION_COUNT=$(echo "${PERMISSIONS}" | jq length)
    echo "Record count (this page): ${PERMISSION_COUNT}"
    echo ""
    printf "%-42s | %-10s | %s\n" "permissionId" "flags" "decoded"
    echo "--------------------------------------------------------------------------------------------------------"

    local p
    for (( p=0; p<PERMISSION_COUNT; p++ )); do
        PERMISSION_ID=$(echo "$PERMISSIONS" | jq -r ".[${p}].permissionId")
        local pflags
        pflags=$(echo "$PERMISSIONS" | jq -r ".[${p}].value")
        PERMISSION_READABLE=$(display_permissions "$pflags")
        printf "%-42s | %-10s | %s\n" "$PERMISSION_ID" "$pflags" "$PERMISSION_READABLE"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}
