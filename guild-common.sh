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
    GUILD_TOKEN_DENOM_SMALL=$(jq -r '.guild.denom["0"]' "$GUILD_CONFIG_FILE")

    # Get reactor details
    REACTOR_ID=$(echo "$GUILD_JSON" | jq -r '.Guild.primaryReactorId')
    REACTOR_JSON=$(structsd ${PARAMS_QUERY} query structs reactor ${REACTOR_ID})
    REACTOR_FUEL=$(echo "$REACTOR_JSON" | jq -r '.gridAttributes.fuel')
    REACTOR_LOAD=$(echo "$REACTOR_JSON" | jq -r '.gridAttributes.load')
    REACTOR_CAPACITY=$(echo "$REACTOR_JSON" | jq -r '.gridAttributes.capacity')

    #Check if values are null and set defaults
    if [[ -z "$REACTOR_FUEL" || "$REACTOR_FUEL" == "null" ]]; then
        REACTOR_FUEL=0
    fi
        
    if [[ -z "$REACTOR_LOAD" || "$REACTOR_LOAD" == "null" ]]; then
        REACTOR_LOAD=0
    fi
    
    if [[ -z "$REACTOR_CAPACITY" || "$REACTOR_CAPACITY" == "null" ]]; then
        REACTOR_CAPACITY=0
    fi

    # Get entry substation details
    ENTRY_SUBSTATION_ID=$(echo "$GUILD_JSON" | jq -r '.Guild.entrySubstationId')
    SUBSTATION_JSON=$(structsd ${PARAMS_QUERY} query structs substation ${ENTRY_SUBSTATION_ID})
    SUBSTATION_LOAD=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.load')
    SUBSTATION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.capacity')
    SUBSTATION_CONNECTION_COUNT=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCount')
    SUBSTATION_CONNECTION_CAPACITY=$(echo "$SUBSTATION_JSON" | jq -r '.gridAttributes.connectionCapacity')

    #Check if values are null and set defaults
    if [[ -z "$SUBSTATION_LOAD" || "$SUBSTATION_LOAD" == "null" ]]; then
        SUBSTATION_LOAD=0
    fi
    
    if [[ -z "$SUBSTATION_CAPACITY" || "$SUBSTATION_CAPACITY" == "null" ]]; then
        SUBSTATION_CAPACITY=0
    fi
    
    if [[ -z "$SUBSTATION_CONNECTION_COUNT" || "$SUBSTATION_CONNECTION_COUNT" == "null" ]]; then
        SUBSTATION_CONNECTION_COUNT=0
    fi
    
    if [[ -z "$SUBSTATION_CONNECTION_CAPACITY" || "$SUBSTATION_CONNECTION_CAPACITY" == "null" ]]; then
        SUBSTATION_CONNECTION_CAPACITY=0
    fi

    # Get account balances
    UALPHA_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} ualpha | jq -r '.balance.amount')
    TOKEN_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} "uguild.${GUILD_ID}" | jq -r '.balance.amount')

    echo -e "${CYAN}=== GUILD DETAILS ===${NC}"
    echo -e "${YELLOW}Guild ID:${NC} ${GUILD_ID}"
    echo -e "${YELLOW}Guild Name:${NC} ${GUILD_NAME}"
    echo -e "${YELLOW}Description:${NC} ${GUILD_DESCRIPTION}"
    echo ""

    echo -e "${CYAN}=== REACTOR DETAILS ===${NC}"
    echo -e "${YELLOW}Reactor ID:${NC} ${REACTOR_ID}"
    echo -e "${YELLOW}Fuel:${NC} ${REACTOR_FUEL}"
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
    echo -e "${YELLOW}Alpha Balance:${NC} ${UALPHA_BALANCE}ualpha"
    echo -e "${YELLOW}Token Balance:${NC} ${TOKEN_BALANCE}${GUILD_TOKEN_DENOM_SMALL} (uguild.${GUILD_ID}) "
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