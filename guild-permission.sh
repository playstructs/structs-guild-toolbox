#!/bin/bash

function permissions_menu() {
    print_header

    # Get guild details
    GUILD_JSON=$(structsd ${PARAMS_QUERY} query structs guild ${GUILD_ID})
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    # Get player address and ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    echo -e "${CYAN}=== PERMISSIONS MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo -e "${YELLOW}Player ID:${NC} ${PLAYER_ID}"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Proxy Join (Add Member)"
    echo -e "${GREEN}2.${NC} Grant Permission"
    echo -e "${GREEN}3.${NC} Revoke Permission"
    echo -e "${GREEN}4.${NC} View Permissions"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " PERM_OPTION

    case $PERM_OPTION in
        1) proxy_join ;;
        2) grant_permission ;;
        3) revoke_permission ;;
        4) view_permissions ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            permissions_menu
            ;;
    esac
}

function select_permissions() {
    local current_permissions=0
    local done=false

    while [ "$done" = false ]; do
        print_header
        echo -e "${CYAN}=== SELECT PERMISSIONS ===${NC}"
        echo ""

        # Display current selection
        echo -e "${YELLOW}Current selection:${NC}"
        if [ $current_permissions -eq 0 ]; then
            echo -e "  ${RED}None (Permissionless)${NC}"
        else
            if (( $current_permissions & 1 )); then echo -e "  ${GREEN}✓${NC} Play"; else echo -e "  ${RED}✗${NC} Play"; fi
            if (( $current_permissions & 2 )); then echo -e "  ${GREEN}✓${NC} Update"; else echo -e "  ${RED}✗${NC} Update"; fi
            if (( $current_permissions & 4 )); then echo -e "  ${GREEN}✓${NC} Delete"; else echo -e "  ${RED}✗${NC} Delete"; fi
            if (( $current_permissions & 8 )); then echo -e "  ${GREEN}✓${NC} Assets"; else echo -e "  ${RED}✗${NC} Assets"; fi
            if (( $current_permissions & 16 )); then echo -e "  ${GREEN}✓${NC} Associations"; else echo -e "  ${RED}✗${NC} Associations"; fi
            if (( $current_permissions & 32 )); then echo -e "  ${GREEN}✓${NC} Grid"; else echo -e "  ${RED}✗${NC} Grid"; fi
            if (( $current_permissions & 64 )); then echo -e "  ${GREEN}✓${NC} Permissions"; else echo -e "  ${RED}✗${NC} Permissions"; fi
        fi
        echo ""

        echo -e "${CYAN}Toggle options:${NC}"
        echo -e "${GREEN}1.${NC} Play"
        echo -e "${GREEN}2.${NC} Update"
        echo -e "${GREEN}3.${NC} Delete"
        echo -e "${GREEN}4.${NC} Assets"
        echo -e "${GREEN}5.${NC} Associations"
        echo -e "${GREEN}6.${NC} Grid"
        echo -e "${GREEN}7.${NC} Permissions"
        echo -e "${GREEN}8.${NC} All (select all)"
        echo -e "${GREEN}9.${NC} None (clear all)"
        echo -e "${GREEN}0.${NC} Done"
        echo ""

        read -p "Select an option: " PERM_OPTION

        case $PERM_OPTION in
            1) current_permissions=$((current_permissions ^ 1)) ;; # Toggle Play
            2) current_permissions=$((current_permissions ^ 2)) ;; # Toggle Update
            3) current_permissions=$((current_permissions ^ 4)) ;; # Toggle Delete
            4) current_permissions=$((current_permissions ^ 8)) ;; # Toggle Assets
            5) current_permissions=$((current_permissions ^ 16)) ;; # Toggle Associations
            6) current_permissions=$((current_permissions ^ 32)) ;; # Toggle Grid
            7) current_permissions=$((current_permissions ^ 64)) ;; # Toggle Permissions
            8) current_permissions=127 ;; # All permissions (1+2+4+8+16+32+64)
            9) current_permissions=0 ;; # No permissions
            0) done=true ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 1
                ;;
        esac
    done

    # Return the numeric value directly
    echo "$current_permissions"
}
function display_permissions() {
    local permission_value="$1"
    local permission_string=""
    local first=true

    # Make sure we have a valid number
    if [[ ! "$permission_value" =~ ^[0-9]+$ ]]; then
        echo "Unknown"
        return
    fi

    if [ "$permission_value" -eq 0 ]; then
        echo "None (Permissionless)"
        return
    fi

    if [ "$permission_value" -eq 127 ]; then
        echo "All Permissions"
        return
    fi

    # Check each bit flag
    if (( (permission_value & 1) != 0 )); then
        permission_string="Play"
        first=false
    fi

    if (( (permission_value & 2) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Update"
            first=false
        else
            permission_string="${permission_string}, Update"
        fi
    fi

    if (( (permission_value & 4) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Delete"
            first=false
        else
            permission_string="${permission_string}, Delete"
        fi
    fi

    if (( (permission_value & 8) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Assets"
            first=false
        else
            permission_string="${permission_string}, Assets"
        fi
    fi

    if (( (permission_value & 16) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Associations"
            first=false
        else
            permission_string="${permission_string}, Associations"
        fi
    fi

    if (( (permission_value & 32) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Grid"
            first=false
        else
            permission_string="${permission_string}, Grid"
        fi
    fi

    if (( (permission_value & 64) != 0 )); then
        if [ "$first" = true ]; then
            permission_string="Permissions"
            first=false
        else
            permission_string="${permission_string}, Permissions"
        fi
    fi

    echo "$permission_string"
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

    echo -e "${YELLOW}Adding player ${TARGET_PLAYER_ID} to guild...${NC}"
    structsd ${PARAMS_TX} tx structs guild-membership-join-proxy ${TARGET_PLAYER_ADDRESS} ${TARGET_PLAYER_PUBKEY} ${TARGET_PLAYER_SIGNATURE} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Player added successfully!${NC}"
    press_enter_to_continue
    permissions_menu
}

function grant_permission() {
    print_header
    echo -e "${CYAN}=== GRANT PERMISSION ===${NC}"
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

    # Verify player exists
    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Now select the specific permissions to grant:${NC}"
    PERMISSION_FLAGS=$(select_permissions)
    PERMISSION_READABLE=$(display_permissions $PERMISSION_FLAGS)

    echo -e "${YELLOW}Granting ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) permission to player ${TARGET_PLAYER_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-grant-on-object ${TARGET_OBJECT_ID} ${TARGET_PLAYER_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Permission granted successfully!${NC}"
    press_enter_to_continue
    permissions_menu
}

function revoke_permission() {
    print_header
    echo -e "${CYAN}=== REVOKE PERMISSION ===${NC}"
    echo ""


    read -p "Enter Object ID to revoke permission on: " TARGET_OJBECT_ID

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

    # Verify player exists
    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    echo -e "${YELLOW}Now select the specific permissions to revoke:${NC}"
    PERMISSION_FLAGS=$(select_permissions)
    PERMISSION_READABLE=$(display_permissions $PERMISSION_FLAGS)

    echo -e "${YELLOW}Revoking ${PERMISSION_READABLE} (${PERMISSION_FLAGS}) permission from player ${TARGET_PLAYER_ID} on ${TARGET_OBJECT_ID}...${NC}"
    structsd ${PARAMS_TX} tx structs permission-revoke-on-object ${TARGET_OBJECT_ID} ${TARGET_PLAYER_ID} ${PERMISSION_FLAGS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Permission revoked successfully!${NC}"
    press_enter_to_continue
    permissions_menu
}

function view_permissions() {
    print_header
    echo -e "${CYAN}=== VIEW PERMISSIONS ===${NC}"
    echo ""

    read -p "Enter Object ID to view permission on: " TARGET_OBJECT_ID

    if [[ -z "$TARGET_OBJECT_ID" ]]; then
        echo -e "${RED}Object ID cannot be empty.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi

    # Get all permissions for the guild
    PERMISSIONS_JSON=$(structsd ${PARAMS_QUERY} query structs permission-by-object ${TARGET_OBJECT_ID})
    PERMISSIONS=$(echo "$PERMISSIONS_JSON" | jq -r '.permissionRecords' 2>/dev/null)

    if [[ -z "$PERMISSIONS" || "$PERMISSIONS" == "null" ]]; then
        echo -e "${YELLOW}No permissions found for this object.${NC}"
        press_enter_to_continue
        permissions_menu
        return
    fi


    echo -e "${CYAN}Current Permissions: ${TARGET_OBJECT_ID} ${NC}"
    echo ""
    echo -e "${YELLOW}Player ID | Permission Type | Permission${NC}"
    echo -e "-------------------------------------------"

    PERMISSION_COUNT=`echo ${PERMISSIONS} | jq length `
    for (( p=0; p<PERMISSION_COUNT; p++ ))
    do
        PERMISSION_ID=$(echo "$PERMISSIONS" | jq -r '.[${p}].permissionId')
        TARGET_PLAYER_ID=${PERMISSION_ID#*@}
        PERMISSION_FLAGS=$(echo "$PERMISSIONS" | jq -r '.[${p}].value')
        PERMISSION_READABLE=$(display_permissions $PERMISSION_FLAGS)


        echo -e "${TARGET_PLAYER_ID} | ${PERMISSION_READABLE} | ${PERMISSION_FLAGS}"
    done

    echo ""
    press_enter_to_continue
    permissions_menu
}