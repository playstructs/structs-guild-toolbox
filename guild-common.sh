#!/bin/bash

# Helper functions
function print_header() {
    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}             STRUCTS GUILD ADMINISTRATION             ${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo ""
}

function print_footer() {
    echo ""
    echo -e "${BLUE}======================================================${NC}"
    echo ""
}

function press_enter_to_continue() {
    echo ""
    read -p "Press Enter to continue..."
}

# Main function to display the main screen
function display_main_screen() {
    print_header

    # Get player address and ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    # Get guild details
    GUILD_JSON=$(structsd ${PARAMS_QUERY} query structs guild ${GUILD_ID})
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")
    GUILD_DESCRIPTION=$(jq -r '.guild.description' "$GUILD_CONFIG_FILE")
    GUILD_TOKEN_DENOM=$(jq -r '.guild.denom["6"]' "$GUILD_CONFIG_FILE")

    # Get reactor details
    REACTOR_ID=$(echo "$GUILD_JSON" | jq -r '.Guild.reactorId')
    REACTOR_JSON=$(structsd ${PARAMS_QUERY} query structs reactor ${REACTOR_ID})
    REACTOR_LOAD=$(echo "$REACTOR_JSON" | jq -r '.Reactor.load')
    REACTOR_CAPACITY=$(echo "$REACTOR_JSON" | jq -r '.Reactor.capacity')

    # Get entry substation details
    ENTRY_SUBSTATION_ID=$(echo "$GUILD_JSON" | jq -r '.Guild.entrySubstationId')
    SUBSTATION_JSON=$(structsd ${PARAMS_QUERY} query structs substation ${ENTRY_SUBSTATION_ID})
    SUBSTATION_LOAD=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.load')
    SUBSTATION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.capacity')
    SUBSTATION_CONNECTION_COUNT=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.connectionCount')
    SUBSTATION_CONNECTION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.Substation.connectionCapacity')

    # Get account balances
    UALPHA_BALANCE=$(structsd query bank balance ${PLAYER_ADDRESS} ualpha -o json | jq -r '.amount')
    TOKEN_BALANCE=$(structsd query bank balance ${PLAYER_ADDRESS} "uguild.${GUILD_ID}" -o json | jq -r '.amount')

    echo -e "${CYAN}=== GUILD DETAILS ===${NC}"
    echo -e "${YELLOW}Guild ID:${NC} ${GUILD_ID}"
    echo -e "${YELLOW}Guild Name:${NC} ${GUILD_NAME}"
    echo -e "${YELLOW}Description:${NC} ${GUILD_DESCRIPTION}"
    echo ""

    echo -e "${CYAN}=== REACTOR DETAILS ===${NC}"
    echo -e "${YELLOW}Reactor ID:${NC} ${REACTOR_ID}"
    echo -e "${YELLOW}Load/Capacity:${NC} ${REACTOR_LOAD}/${REACTOR_CAPACITY}"
    echo ""

    echo -e "${CYAN}=== ENTRY SUBSTATION DETAILS ===${NC}"
    echo -e "${YELLOW}Substation ID:${NC} ${ENTRY_SUBSTATION_ID}"
    echo -e "${YELLOW}Load/Capacity:${NC} ${SUBSTATION_LOAD}/${SUBSTATION_CAPACITY}"
    echo -e "${YELLOW}Connections:${NC} ${SUBSTATION_CONNECTION_COUNT}/${SUBSTATION_CONNECTION_CAPACITY}"
    echo ""

    echo -e "${CYAN}=== ACCOUNT DETAILS ===${NC}"
    echo -e "${YELLOW}Account:${NC} ${STRUCTS_ACCOUNT}"
    echo -e "${YELLOW}Player ID:${NC} ${PLAYER_ID}"
    echo -e "${YELLOW}Alpha Balance:${NC} ${UALPHA_BALANCE} ualpha"
    echo -e "${YELLOW}Token Balance:${NC} ${TOKEN_BALANCE} u${GUILD_TOKEN_DENOM}"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Energy Grid"
    echo -e "${GREEN}3.${NC} Central Bank"
    echo -e "${GREEN}4.${NC} Membership"
    echo -e "${GREEN}5.${NC} Guild Configuration"
    echo -e "${GREEN}6.${NC} Permissions"
    echo -e "${GREEN}0.${NC} Exit"
    echo ""

    read -p "Select an option: " MAIN_OPTION

    case $MAIN_OPTION in
        1) display_main_screen ;;
        2) energy_grid_menu ;;
        3) central_bank_menu ;;
        4) membership_menu ;;
        5) guild_configuration_menu ;;
        6) permissions_menu ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            display_main_screen
            ;;
    esac
}