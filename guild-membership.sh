#!/bin/bash
#
# Guild membership: applications (invites we sent, requests players sent),
# approvals, denials, revocations, kicks and the member list.

function _membership_pending() {
    # Pending (proposed) applications for this guild, one JSON object per line
    sx_q_all GuildMembershipApplication structs guild-membership-application-all \
        | jq -c --arg g "$GUILD_ID" 'select(.guildId == $g and ((.registrationStatus // "proposed") == "proposed"))'
}

function membership_menu() {
    print_header
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    echo -e "${CYAN}=== MEMBERSHIP MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo ""

    PENDING=$(_membership_pending)
    echo -e "${CYAN}=== PENDING APPLICATIONS ===${NC}"
    if [ -z "$PENDING" ]; then
        echo "  (none)"
    else
        printf "  %-4s %-12s %-9s %-14s %s\n" "#" "PLAYER" "TYPE" "SUBSTATION" "PROPOSER"
        local i=0
        while read -r app; do
            i=$((i + 1))
            printf "  %-4s %-12s %-9s %-14s %s\n" "$i" \
                "$(echo "$app" | jq -r .playerId)" \
                "$(echo "$app" | jq -r '.joinType // "invite"')" \
                "$(echo "$app" | jq -r '.substationId // "-"')" \
                "$(echo "$app" | jq -r '.proposer // "-"')"
        done <<<"$PENDING"
    fi
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Invite a player"
    echo -e "${GREEN}3.${NC} Handle a pending application (approve / deny / revoke)"
    echo -e "${GREEN}4.${NC} Kick a member"
    echo -e "${GREEN}5.${NC} List members"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " MEMBERSHIP_OPTION

    case $MEMBERSHIP_OPTION in
        1) membership_menu ;;
        2) start_application_invite ;;
        3) review_applications ;;
        4) kick_member ;;
        5) list_members ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            membership_menu
            ;;
    esac
}

function _membership_back() { press_enter_to_continue; membership_menu; }

function start_application_invite() {
    print_header
    echo -e "${CYAN}=== INVITE A PLAYER ===${NC}"
    echo ""
    read -p "Player ID to invite: " TARGET_PLAYER_ID
    if ! sx_is_player_id "$TARGET_PLAYER_ID"; then
        echo -e "${RED}Not a player ID (expected 1-N).${NC}"; _membership_back; return
    fi
    if [ -z "$(sx_q structs player "$TARGET_PLAYER_ID" | jq -r '.Player.id // empty')" ]; then
        echo -e "${RED}Player ${TARGET_PLAYER_ID} not found.${NC}"; _membership_back; return
    fi
    sx_tx_reset
    sx_tx_add structs guild-membership-invite "$TARGET_PLAYER_ID"
    sx_confirm "Invite ${TARGET_PLAYER_ID} to ${GUILD_ID}?" && sx_tx_run
    _membership_back
}

function review_applications() {
    PENDING=$(_membership_pending)
    if [ -z "$PENDING" ]; then
        echo -e "${YELLOW}No pending applications.${NC}"; _membership_back; return
    fi
    read -p "Application # (from the list): " N
    APP=$(echo "$PENDING" | sed -n "${N}p")
    if [ -z "$APP" ]; then
        echo -e "${RED}No application #${N}.${NC}"; _membership_back; return
    fi
    TARGET_PLAYER_ID=$(echo "$APP" | jq -r .playerId)
    JOIN_TYPE=$(echo "$APP" | jq -r '.joinType // "invite"')

    sx_tx_reset
    if [ "$JOIN_TYPE" = "request" ]; then
        echo -e "${TARGET_PLAYER_ID} ${BOLD}requested${NC} to join."
        echo -e "${GREEN}1.${NC} Approve   ${GREEN}2.${NC} Deny   ${GREEN}0.${NC} Back"
        read -p "Select: " A
        case "$A" in
            1) sx_tx_add structs guild-membership-request-approve "$TARGET_PLAYER_ID" --guild-id "$GUILD_ID" ;;
            2) sx_tx_add structs guild-membership-request-deny "$TARGET_PLAYER_ID" --guild-id "$GUILD_ID" ;;
            *) membership_menu; return ;;
        esac
    else
        echo -e "You ${BOLD}invited${NC} ${TARGET_PLAYER_ID}; they have not answered yet."
        echo -e "${GREEN}1.${NC} Revoke the invite   ${GREEN}0.${NC} Back"
        read -p "Select: " A
        case "$A" in
            1) sx_tx_add structs guild-membership-invite-revoke "$GUILD_ID" "$TARGET_PLAYER_ID" ;;
            *) membership_menu; return ;;
        esac
    fi
    sx_confirm "Confirm?" && sx_tx_run
    _membership_back
}

function kick_member() {
    print_header
    echo -e "${CYAN}=== KICK A MEMBER ===${NC}"
    read -p "Player ID to kick: " TARGET_PLAYER_ID
    local g
    g=$(sx_q structs player "$TARGET_PLAYER_ID" | jq -r '.Player.guildId // empty')
    if [ "$g" != "$GUILD_ID" ]; then
        echo -e "${RED}${TARGET_PLAYER_ID} is not a member of ${GUILD_ID}.${NC}"; _membership_back; return
    fi
    sx_tx_reset
    sx_tx_add structs guild-membership-kick "$TARGET_PLAYER_ID" --guild-id "$GUILD_ID"
    sx_confirm "Kick ${TARGET_PLAYER_ID} from ${GUILD_ID}?" && sx_tx_run
    _membership_back
}

function list_members() {
    print_header
    echo -e "${CYAN}=== MEMBERS OF ${GUILD_ID} ===${NC}"
    sx_info "Scanning players..."
    printf "  %-12s %-6s %-24s %s\n" "PLAYER" "RANK" "NAME" "SUBSTATION"
    sx_q_all Player structs player-all \
        | jq -r --arg g "$GUILD_ID" 'select(.guildId == $g) | "\(.id)\t\(.guildRank // "-")\t\(.name // "")\t\(.substationId // "-")"' \
        | sort -t$'\t' -k2,2n \
        | while IFS=$'\t' read -r id rank name sub; do printf "  %-12s %-6s %-24s %s\n" "$id" "$rank" "${name:0:24}" "$sub"; done
    _membership_back
}
