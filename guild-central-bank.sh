#!/bin/bash

function central_bank_menu() {
    print_header

    # Get guild details
    GUILD_JSON=$(structsd ${PARAMS_QUERY} query structs guild ${GUILD_ID})
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    # Get player address and ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    # Get token details

    # Collateral Address
    COLLATERAL_ADDRESS=$(structsd ${PARAMS_QUERY} query structs guild-bank-collateral-address ${GUILD_ID} | jq -r .internalAddressAssociation.address )

    # Collateral Balance
    ALPHA_COLLATERAL=$(structsd ${PARAMS_QUERY} query bank balance ${COLLATERAL_ADDRESS} "ualpha" | jq -r .balance.amount )

    # Token Supply
    TOKEN_SUPPLY=$(structsd ${PARAMS_QUERY} query bank total-supply-of "uguild.${GUILD_ID}" | jq -r .amount.amount )

    UALPHA_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} ualpha | jq -r '.balance.amount')
    UTOKEN_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} "uguild.${GUILD_ID}" | jq -r '.balance.amount')

    # Calculate redemption value
    if [ "$TOKEN_SUPPLY" -eq 0 ]; then
        REDEMPTION_VALUE="N/A"
    else
        REDEMPTION_VALUE=$(echo "scale=6; $ALPHA_COLLATERAL / $TOKEN_SUPPLY" | bc)
    fi

    echo -e "${CYAN}=== CENTRAL BANK MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo -e "${YELLOW}Player ID:${NC} ${PLAYER_ID}"
    echo ""

    echo -e "${CYAN}=== BANK DETAILS ===${NC}"
    echo -e "${YELLOW}Alpha Collateral:${NC} ${ALPHA_COLLATERAL} ualpha"
    echo -e "${YELLOW}Token Supply:${NC} ${TOKEN_SUPPLY} utoken"
    echo -e "${YELLOW}Current Redemption Value:${NC} ${REDEMPTION_VALUE} ualpha per utoken"
    echo ""

    echo -e "${CYAN}=== ACCOUNT BALANCES ===${NC}"
    echo -e "${YELLOW}Alpha Balance:${NC} ${UALPHA_BALANCE} ualpha"
    echo -e "${YELLOW}Token Balance:${NC} ${UTOKEN_BALANCE} utoken"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Mint Tokens"
    echo -e "${GREEN}3.${NC} Transfer Tokens"
    echo -e "${GREEN}4.${NC} Redeem Tokens"
    echo -e "${GREEN}5.${NC} Confiscate and Burn Tokens"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " BANK_OPTION

    case $BANK_OPTION in
        1) central_bank_menu ;;
        2) mint_tokens ;;
        3) transfer_tokens ;;
        4) redeem_tokens ;;
        5) confiscate_tokens ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            central_bank_menu
            ;;
    esac
}

function mint_tokens() {
    print_header
    echo -e "${CYAN}=== MINT TOKENS ===${NC}"
    echo ""

    # Get account balances
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    UALPHA_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} ualpha | jq -r '.balance.amount')

    echo -e "${YELLOW}Available Alpha Balance:${NC} ${UALPHA_BALANCE} ualpha"
    echo ""

    read -p "Enter amount of ualpha to use as collateral: " ALPHA_AMOUNT

    if ! [[ "$ALPHA_AMOUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a valid number.${NC}"
        press_enter_to_continue
        mint_tokens
        return
    fi

    if [ "$ALPHA_AMOUNT" -gt "$UALPHA_BALANCE" ]; then
        echo -e "${RED}Insufficient balance. You only have ${UALPHA_BALANCE} ualpha.${NC}"
        press_enter_to_continue
        mint_tokens
        return
    fi

    read -p "Enter amount of utoken to mint: " TOKEN_AMOUNT

    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a valid number.${NC}"
        press_enter_to_continue
        mint_tokens
        return
    fi

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Deposit ${ALPHA_AMOUNT} ualpha as collateral"
    echo -e "- Mint ${TOKEN_AMOUNT} utoken"
    echo ""
    read -p "Confirm this transaction? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Transaction cancelled.${NC}"
        press_enter_to_continue
        central_bank_menu
        return
    fi

    echo -e "${YELLOW}Minting tokens...${NC}"
    structsd ${PARAMS_TX} tx structs guild-bank-mint ${GUILD_ID} ${ALPHA_AMOUNT} ${TOKEN_AMOUNT} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Tokens minted successfully!${NC}"
    press_enter_to_continue
    central_bank_menu
}

function transfer_tokens() {
    print_header
    echo -e "${CYAN}=== TRANSFER TOKENS ===${NC}"
    echo ""

    # Get account balances
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    ACCOUNT_BALANCES=$(structsd ${PARAMS_QUERY} query bank balances ${PLAYER_ADDRESS})
    UTOKEN_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} "uguild.${GUILD_ID}" | jq -r '.balance.amount')

    echo -e "${YELLOW}Available Token Balance:${NC} ${UTOKEN_BALANCE} utoken"
    echo ""

    read -p "Enter amount of utoken to transfer: " TOKEN_AMOUNT

    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a valid number.${NC}"
        press_enter_to_continue
        transfer_tokens
        return
    fi

    if [ "$TOKEN_AMOUNT" -gt "$UTOKEN_BALANCE" ]; then
        echo -e "${RED}Insufficient balance. You only have ${UTOKEN_BALANCE} utoken.${NC}"
        press_enter_to_continue
        transfer_tokens
        return
    fi

    read -p "Enter destination address: " DESTINATION_ADDRESS

    if [[ -z "$DESTINATION_ADDRESS" ]]; then
        echo -e "${RED}Destination address cannot be empty.${NC}"
        press_enter_to_continue
        transfer_tokens
        return
    fi

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Transfer ${TOKEN_AMOUNT} utoken"
    echo -e "- To address: ${DESTINATION_ADDRESS}"
    echo ""
    read -p "Confirm this transaction? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Transaction cancelled.${NC}"
        press_enter_to_continue
        central_bank_menu
        return
    fi

    echo -e "${YELLOW}Transferring tokens...${NC}"
    structsd ${PARAMS_TX} tx bank send ${PLAYER_ADDRESS} ${DESTINATION_ADDRESS} "${TOKEN_AMOUNT}uguild.${GUILD_ID}" --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Tokens transferred successfully!${NC}"
    press_enter_to_continue
    central_bank_menu
}

function redeem_tokens() {
    print_header
    echo -e "${CYAN}=== REDEEM TOKENS ===${NC}"
    echo ""


    # Collateral Address
    COLLATERAL_ADDRESS=$(structsd ${PARAMS_QUERY} query structs guild-bank-collateral-address ${GUILD_ID} | jq -r .internalAddressAssociation.address )

    # Collateral Balance
    ALPHA_COLLATERAL=$(structsd ${PARAMS_QUERY} query bank balance ${COLLATERAL_ADDRESS} "ualpha" | jq -r .balance.amount )

    # Token Supply
    TOKEN_SUPPLY=$(structsd ${PARAMS_QUERY} query bank total-supply-of "uguild.${GUILD_ID}" | jq -r .amount.amount )

    # Get account balances
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    UALPHA_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} ualpha | jq -r '.balance.amount')
    UTOKEN_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${PLAYER_ADDRESS} "uguild.${GUILD_ID}" | jq -r '.balance.amount')

    # Calculate redemption value
    if [ "$TOKEN_SUPPLY" -eq 0 ]; then
        REDEMPTION_VALUE="N/A"
        echo -e "${RED}No tokens in circulation. Cannot redeem.${NC}"
        press_enter_to_continue
        central_bank_menu
        return
    else
        REDEMPTION_VALUE=$(echo "scale=6; $ALPHA_COLLATERAL / $TOKEN_SUPPLY" | bc)
    fi

    echo -e "${YELLOW}Available Token Balance:${NC} ${UTOKEN_BALANCE} utoken"
    echo -e "${YELLOW}Current Redemption Value:${NC} ${REDEMPTION_VALUE} ualpha per utoken"
    echo ""

    read -p "Enter amount of utoken to redeem: " TOKEN_AMOUNT

    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a valid number.${NC}"
        press_enter_to_continue
        redeem_tokens
        return
    fi

    if [ "$TOKEN_AMOUNT" -gt "$UTOKEN_BALANCE" ]; then
        echo -e "${RED}Insufficient balance. You only have ${UTOKEN_BALANCE} utoken.${NC}"
        press_enter_to_continue
        redeem_tokens
        return
    fi

    # Calculate expected alpha return
    EXPECTED_ALPHA=$(echo "scale=0; $TOKEN_AMOUNT * $REDEMPTION_VALUE / 1" | bc)

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Redeem ${TOKEN_AMOUNT} utoken"
    echo -e "- Expected return: ~${EXPECTED_ALPHA} ualpha"
    echo ""
    read -p "Confirm this transaction? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Transaction cancelled.${NC}"
        press_enter_to_continue
        central_bank_menu
        return
    fi

    echo -e "${YELLOW}Redeeming tokens...${NC}"
    structsd ${PARAMS_TX} tx structs guild-bank-redeem "${TOKEN_AMOUNT}uguild.${GUILD_ID}" --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Tokens redeemed successfully!${NC}"
    press_enter_to_continue
    central_bank_menu
}

function confiscate_tokens() {
    print_header
    echo -e "${CYAN}=== CONFISCATE AND BURN TOKENS ===${NC}"
    echo ""

    read -p "Enter target address to confiscate from: " TARGET_ADDRESS

    if [[ -z "$TARGET_ADDRESS" ]]; then
        echo -e "${RED}Target address cannot be empty.${NC}"
        press_enter_to_continue
        confiscate_tokens
        return
    fi

    # Get target balances
    TARGET_UTOKEN_BALANCE=$(structsd ${PARAMS_QUERY} query bank balance ${TARGET_ADDRESS} "uguild.${GUILD_ID}")

    echo -e "${YELLOW}Target Token Balance:${NC} ${TARGET_UTOKEN_BALANCE} uguild.${GUILD_ID}"
    echo ""

    read -p "Enter amount of utoken to confiscate and burn: " TOKEN_AMOUNT

    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a valid number.${NC}"
        press_enter_to_continue
        confiscate_tokens
        return
    fi

    if [ "$TOKEN_AMOUNT" -gt "$TARGET_UTOKEN_BALANCE" ]; then
        echo -e "${RED}Insufficient balance. Target only has ${TARGET_UTOKEN_BALANCE}uguild.${GUILD_ID}.${NC}"
        press_enter_to_continue
        confiscate_tokens
        return
    fi

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Confiscate and burn ${TOKEN_AMOUNT} utoken"
    echo -e "- From address: ${TARGET_ADDRESS}"
    echo ""
    read -p "Confirm this transaction? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Transaction cancelled.${NC}"
        press_enter_to_continue
        central_bank_menu
        return
    fi

    echo -e "${YELLOW}Confiscating and burning tokens...${NC}"
    structsd ${PARAMS_TX} tx structs guild-bank-confiscate-and-burn "${TOKEN_AMOUNT}uguild.${GUILD_ID}" ${TARGET_ADDRESS} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Tokens confiscated and burned successfully!${NC}"
    press_enter_to_continue
    central_bank_menu
}