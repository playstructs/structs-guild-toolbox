#!/bin/bash

function energy_grid_menu() {
    print_header

    # Get guild details
    GUILD_JSON=$(structsd ${PARAMS_QUERY} query structs guild ${GUILD_ID})
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    SUBSTATION_ID=$(echo "GUILD_JSON" | jq -r '.Guild.entrySubstationId')


    echo -e "${CYAN}=== ENERGY GRID MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo -e "${YELLOW}Player ID:${NC} ${PLAYER_ID}"
    echo ""

    # Get substation details
    SUBSTATION_JSON=$(structsd ${PARAMS_QUERY} query structs substation ${SUBSTATION_ID})
    if [[ $? -eq 0 ]]; then
        SUBSTATION_ID=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.id')
        SUBSTATION_OWNER=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.owner')
        SUBSTATION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.capacity')
        SUBSTATION_LOAD=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.load')
        SUBSTATION_CONNECTION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCapacity')
        SUBSTATION_CONNECTION_COUNT=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCount')

        echo -e "${CYAN}=== SUBSTATION DETAILS ===${NC}"
        echo -e "${YELLOW}Substation ID:${NC} ${SUBSTATION_ID}"
        echo -e "${YELLOW}Owner:${NC} ${SUBSTATION_OWNER}"
        echo -e "${YELLOW}Capacity:${NC} ${SUBSTATION_CAPACITY}"
        echo -e "${YELLOW}Load:${NC} ${SUBSTATION_LOAD}"
        echo -e "${YELLOW}Connection Capacity:${NC} ${SUBSTATION_CONNECTION_CAPACITY}"
        echo -e "${YELLOW}Connection Count:${NC} ${SUBSTATION_CONNECTION_COUNT}"
    else
        echo -e "${RED}No substation found for this guild.${NC}"
    fi
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Create Provider"
    echo -e "${GREEN}2.${NC} Withdraw Balance"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " ENERGY_OPTION

    case $ENERGY_OPTION in
        1) create_provider ;;
        2) withdraw_balance ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            energy_grid_menu
            ;;
    esac
}

function create_provider() {
    print_header
    echo -e "${CYAN}=== CREATE PROVIDER ===${NC}"
    echo ""

    # Get substation details
    SUBSTATION_JSON=$(structsd ${PARAMS_QUERY} query structs substation ${GUILD_ID})
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}No substation found for this guild.${NC}"
        press_enter_to_continue
        energy_grid_menu
        return
    fi

    SUBSTATION_ID=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.id')
    SUBSTATION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.capacity')
    SUBSTATION_LOAD=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.load')
    SUBSTATION_CONNECTION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCapacity')
    SUBSTATION_CONNECTION_COUNT=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCount')

    echo -e "${YELLOW}Substation ID:${NC} ${SUBSTATION_ID}"
    echo -e "${YELLOW}Available Capacity:${NC} ${SUBSTATION_LOAD} / ${SUBSTATION_CAPACITY}"
    echo ""

    # Ask for provider details
    read -p "Enter rate (utoken per unit, ex: 100ualpha or 2390uguild.${GUILD_ID}}): " RATE


    echo -e "${CYAN}Select access policy:${NC}"
    echo -e "${GREEN}1.${NC} Public"
    echo -e "${GREEN}2.${NC} Guild Only"
    echo -e "${GREEN}3.${NC} Closed"
    read -p "Select access policy (1-3): " ACCESS_POLICY_OPTION

    case $ACCESS_POLICY_OPTION in
        1) ACCESS_POLICY="open-market" ;;
        2) ACCESS_POLICY="guild-market" ;;
        3) ACCESS_POLICY="closed-market" ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            create_provider
            return
            ;;
    esac

    read -p "Enter provider cancellation penalty (ex: 100000000000000000): " PROVIDER_PENALTY
    if ! [[ "$PROVIDER_PENALTY" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid penalty. Please enter a valid number.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    read -p "Enter consumer cancellation penalty (ex: 100000000000000000): " CONSUMER_PENALTY
    if ! [[ "$CONSUMER_PENALTY" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid penalty. Please enter a valid number.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    read -p "Enter minimum capacity: " CAPACITY_MIN
    if ! [[ "$CAPACITY_MIN" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid capacity. Please enter a valid number.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    read -p "Enter maximum capacity: " CAPACITY_MAX
    if ! [[ "$CAPACITY_MAX" =~ ^[0-9]+$ ]] || [ "$CAPACITY_MAX" -lt "$CAPACITY_MIN" ]; then
        echo -e "${RED}Invalid capacity. Please enter a valid number greater than minimum capacity.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    read -p "Enter minimum duration (blocks): " DURATION_MIN
    if ! [[ "$DURATION_MIN" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid duration. Please enter a valid number.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    read -p "Enter maximum duration (blocks): " DURATION_MAX
    if ! [[ "$DURATION_MAX" =~ ^[0-9]+$ ]] || [ "$DURATION_MAX" -lt "$DURATION_MIN" ]; then
        echo -e "${RED}Invalid duration. Please enter a valid number greater than minimum duration.${NC}"
        press_enter_to_continue
        create_provider
        return
    fi

    echo ""
    echo -e "${YELLOW}Provider Details:${NC}"
    echo -e "Substation ID: ${SUBSTATION_ID}"
    echo -e "Rate: ${RATE} ualpha per unit"
    echo -e "Access Policy: ${ACCESS_POLICY}"
    echo -e "Provider Cancellation Penalty: ${PROVIDER_PENALTY} ualpha"
    echo -e "Consumer Cancellation Penalty: ${CONSUMER_PENALTY} ualpha"
    echo -e "Capacity Range: ${CAPACITY_MIN} - ${CAPACITY_MAX}"
    echo -e "Duration Range: ${DURATION_MIN} - ${DURATION_MAX} blocks"
    echo ""

    read -p "Confirm creating this provider? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        energy_grid_menu
        return
    fi

    echo -e "${YELLOW}Creating provider...${NC}"
    TX_RESULT=$(structsd ${PARAMS_TX} tx structs provider-create ${SUBSTATION_ID} ${RATE} ${ACCESS_POLICY} ${PROVIDER_PENALTY} ${CONSUMER_PENALTY} ${CAPACITY_MIN} ${CAPACITY_MAX} ${DURATION_MIN} ${DURATION_MAX} --from ${STRUCTS_ACCOUNT})
    sleep $SLEEP_TIME

    echo -e "${GREEN}Provider (possibly) created successfully!${NC}"
    press_enter_to_continue
    energy_grid_menu
}

function view_provider() {
    print_header
    echo -e "${CYAN}=== VIEW PROVIDER ===${NC}"
    echo ""

    # Get player ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    # Get all providers for this player
    PROVIDERS_JSON=$(structsd ${PARAMS_QUERY} query structs provider-all)
    PROVIDER_COUNT=$(echo "$PROVIDERS_JSON" | jq -r '.Providers | length')

    if [[ "$PROVIDER_COUNT" -eq 0 ]]; then
        echo -e "${YELLOW}No providers found for this player.${NC}"
        echo ""
        echo -e "${CYAN}Options:${NC}"
        echo -e "${GREEN}1.${NC} Enter Provider ID Manually"
        echo -e "${GREEN}0.${NC} Back to Energy Grid Menu"
        echo ""

        read -p "Select an option: " VIEW_OPTION

        case $VIEW_OPTION in
            1)
                read -p "Enter Provider ID: " CURRENT_PROVIDER_ID
                view_provider_details
                ;;
            0) energy_grid_menu ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                press_enter_to_continue
                view_provider
                ;;
        esac
        return
    fi

    echo -e "${CYAN}Your Providers:${NC}"
    echo -e "${YELLOW}ID | Substation | Rate | Access Policy${NC}"
    echo -e "------------------------------"

    echo "$PROVIDERS_JSON" | jq -c '.Providers[]' | while read -r provider; do
        PROVIDER_ID=$(echo "$provider" | jq -r '.id')
        PROVIDER_SUBSTATION=$(echo "$provider" | jq -r '.substationId')
        PROVIDER_RATE=$(echo "$provider" | jq -r '.rate')
        PROVIDER_ACCESS=$(echo "$provider" | jq -r '.accessPolicy')

        echo -e "${PROVIDER_ID} | ${PROVIDER_SUBSTATION} | ${PROVIDER_RATE} | ${PROVIDER_ACCESS}"
    done
    echo ""

    echo -e "${CYAN}Options:${NC}"
    echo -e "${GREEN}1.${NC} Select Provider from List"
    echo -e "${GREEN}2.${NC} Enter Provider ID Manually"
    echo -e "${GREEN}0.${NC} Back to Energy Grid Menu"
    echo ""

    read -p "Select an option: " VIEW_OPTION

    case $VIEW_OPTION in
        1)
            read -p "Enter Provider ID from the list: " CURRENT_PROVIDER_ID
            view_provider_details
            ;;
        2)
            read -p "Enter Provider ID: " CURRENT_PROVIDER_ID
            view_provider_details
            ;;
        0) energy_grid_menu ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            view_provider
            ;;
    esac
}

function withdraw_balance() {
    print_header
    echo -e "${CYAN}=== WITHDRAW BALANCE ===${NC}"
    echo ""

    read -p "Enter Provider ID: " CURRENT_PROVIDER_ID

    echo -e "${YELLOW}Provider ID:${NC} ${CURRENT_PROVIDER_ID}"
    echo ""

    echo -e "${YELLOW}Processing withdrawal...${NC}"
    structsd ${PARAMS_TX} tx structs provider-withdraw-balance ${CURRENT_PROVIDER_ID} ${PLAYER_ADDRESS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Balance withdrawn successfully!${NC}"
    press_enter_to_continue
    view_provider_details
}

function grant_guild() {
    print_header
    echo -e "${CYAN}=== GRANT GUILD ACCESS ===${NC}"
    echo ""

    read -p "Enter Guild ID to grant access to: " TARGET_GUILD_ID

    if [[ -z "$TARGET_GUILD_ID" ]]; then
        echo -e "${RED}Guild ID cannot be empty.${NC}"
        press_enter_to_continue
        grant_guild
        return
    fi

    # Verify guild exists
    GUILD_CHECK=$(structsd ${PARAMS_QUERY} query structs guild ${TARGET_GUILD_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Guild ID ${TARGET_GUILD_ID} not found.${NC}"
        press_enter_to_continue
        grant_guild
        return
    fi

    # Get guild details for confirmation
    GUILD_NAME=$(echo "$GUILD_CHECK" | jq -r '.Guild.name // "Unnamed"')

    echo -e "${YELLOW}Guild Details:${NC}"
    echo -e "ID: ${TARGET_GUILD_ID}"
    echo -e "Name: ${GUILD_NAME}"
    echo ""

    read -p "Confirm granting access to this guild? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        view_provider_details
        return
    fi

    echo -e "${YELLOW}Granting guild access...${NC}"
    structsd ${PARAMS_TX} tx structs provider-grant-guild ${CURRENT_PROVIDER_ID} ${TARGET_GUILD_ID} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Guild access granted successfully!${NC}"
    press_enter_to_continue
    view_provider_details
}

function revoke_guild() {
    print_header
    echo -e "${CYAN}=== REVOKE GUILD ACCESS ===${NC}"
    echo ""

    read -p "Enter Guild ID to revoke access from: " TARGET_GUILD_ID

    if [[ -z "$TARGET_GUILD_ID" ]]; then
        echo -e "${RED}Guild ID cannot be empty.${NC}"
        press_enter_to_continue
        revoke_guild
        return
    fi

    # Verify guild exists
    GUILD_CHECK=$(structsd ${PARAMS_QUERY} query structs guild ${TARGET_GUILD_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Guild ID ${TARGET_GUILD_ID} not found.${NC}"
        press_enter_to_continue
        revoke_guild
        return
    fi

    # Get guild details for confirmation
    GUILD_NAME=$(echo "$GUILD_CHECK" | jq -r '.Guild.name // "Unnamed"')

    echo -e "${YELLOW}Guild Details:${NC}"
    echo -e "ID: ${TARGET_GUILD_ID}"
    echo -e "Name: ${GUILD_NAME}"
    echo ""

    read -p "Confirm revoking access from this guild? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        view_provider_details
        return
    fi

    echo -e "${YELLOW}Revoking guild access...${NC}"
    structsd ${PARAMS_TX} tx structs provider-revoke-guild ${CURRENT_PROVIDER_ID} ${TARGET_GUILD_ID} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Guild access revoked successfully!${NC}"
    press_enter_to_continue
    view_provider_details
}
