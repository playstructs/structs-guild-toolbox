#!/bin/bash
#
# Central bank. How the chain moves funds (x/structs/keeper/guild_cache.go):
#   mint     guild VAULT treasury alpha -> collateral pool; tokens -> guild vault
#   convert  your PLAYER VAULT alpha    -> collateral pool; tokens -> your vault
#   redeem   your PLAYER VAULT tokens   -> burned; alpha     -> your vault
# Convert/redeem need a slippage guard; we quote from the live ratio and
# accept up to BANK_SLIPPAGE_BPS (default 1%) worse.

BANK_SLIPPAGE_BPS="${BANK_SLIPPAGE_BPS:-100}"

function _bank_load() {
    GUILD_DENOM="uguild.${GUILD_ID}"
    GUILD_VAULT=$(sx_vault_of "$GUILD_ID")
    PLAYER_VAULT=$(sx_vault_of "$PLAYER_ID")
    COLLATERAL_ADDRESS=$(sx_q structs guild-bank-collateral-address "$GUILD_ID" | jq -r '.internalAddressAssociation[0].address // empty')
    ALPHA_COLLATERAL=$(sx_q bank balance "$COLLATERAL_ADDRESS" ualpha | jq -r '.balance.amount // "0"')
    TOKEN_SUPPLY=$(sx_q bank total-supply-of "$GUILD_DENOM" | jq -r '.amount.amount // "0"')
    TREASURY_ALPHA=$(sx_q bank balance "$GUILD_VAULT" ualpha | jq -r '.balance.amount // "0"')
    TREASURY_TOKEN=$(sx_q bank balance "$GUILD_VAULT" "$GUILD_DENOM" | jq -r '.balance.amount // "0"')
    VAULT_ALPHA=$(sx_q bank balance "$PLAYER_VAULT" ualpha | jq -r '.balance.amount // "0"')
    VAULT_TOKEN=$(sx_q bank balance "$PLAYER_VAULT" "$GUILD_DENOM" | jq -r '.balance.amount // "0"')
    local g
    g=$(sx_q structs guild "$GUILD_ID")
    FEE_IN=$(echo "$g" | jq -r '.Guild.bankConvertInFee // "0"')
    FEE_OUT=$(echo "$g" | jq -r '.Guild.bankConvertOutFee // "0"')
}

function central_bank_menu() {
    print_header
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")
    _bank_load

    if sx_is_zero "$TOKEN_SUPPLY"; then
        REDEMPTION_VALUE="N/A (no supply)"
    else
        REDEMPTION_VALUE="$(echo "scale=6; $ALPHA_COLLATERAL / $TOKEN_SUPPLY" | bc) ualpha per token unit"
    fi

    echo -e "${CYAN}=== CENTRAL BANK MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})   ${YELLOW}Denom:${NC} ${GUILD_DENOM}"
    echo ""
    echo -e "${CYAN}=== BANK ===${NC}"
    echo -e "${YELLOW}Alpha collateral:${NC}   $(sx_fmt "$ALPHA_COLLATERAL")"
    echo -e "${YELLOW}Token supply:${NC}       $(sx_fmt "$TOKEN_SUPPLY" "$GUILD_DENOM")"
    echo -e "${YELLOW}Redemption value:${NC}   ${REDEMPTION_VALUE}"
    echo -e "${YELLOW}Fees:${NC}               convert-in ${FEE_IN}, convert-out ${FEE_OUT}"
    echo ""
    echo -e "${CYAN}=== GUILD VAULT (treasury) ===${NC}  ${GUILD_VAULT}"
    echo -e "${YELLOW}Alpha:${NC}  $(sx_fmt "$TREASURY_ALPHA")   ${YELLOW}Tokens:${NC} $(sx_fmt "$TREASURY_TOKEN" "$GUILD_DENOM")"
    echo ""
    echo -e "${CYAN}=== YOUR PLAYER VAULT ===${NC}  ${PLAYER_VAULT}"
    echo -e "${YELLOW}Alpha:${NC}  $(sx_fmt "$VAULT_ALPHA")   ${YELLOW}Tokens:${NC} $(sx_fmt "$VAULT_TOKEN" "$GUILD_DENOM")"
    echo -e "${DIM}Convert and redeem use your player vault. Wallet (main menu 7) moves funds into it.${NC}"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Mint tokens (from guild treasury)"
    echo -e "${GREEN}3.${NC} Transfer tokens"
    echo -e "${GREEN}4.${NC} Redeem tokens for alpha"
    echo -e "${GREEN}5.${NC} Convert alpha into tokens"
    echo -e "${GREEN}6.${NC} Confiscate and burn tokens"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " BANK_OPTION

    case $BANK_OPTION in
        1) central_bank_menu ;;
        2) mint_tokens ;;
        3) transfer_tokens ;;
        4) redeem_tokens ;;
        5) convert_alpha ;;
        6) confiscate_tokens ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            central_bank_menu
            ;;
    esac
}

function _bank_back() { press_enter_to_continue; central_bank_menu; }

function mint_tokens() {
    print_header
    echo -e "${CYAN}=== MINT TOKENS ===${NC}"
    _bank_load
    echo -e "Minting spends the ${BOLD}guild vault${NC} treasury, not your own funds."
    echo -e "${YELLOW}Treasury alpha:${NC} $(sx_fmt "$TREASURY_ALPHA") (${TREASURY_ALPHA} ualpha)"
    echo ""

    read -p "Alpha collateral (ualpha): " ALPHA_AMOUNT
    if ! [[ "$ALPHA_AMOUNT" =~ ^[0-9]+$ ]] || sx_is_zero "$ALPHA_AMOUNT"; then
        echo -e "${RED}Invalid amount.${NC}"; _bank_back; return
    fi
    if [ "$(sx_cmp "$ALPHA_AMOUNT" "$TREASURY_ALPHA")" = "1" ]; then
        echo -e "${RED}The guild treasury only has ${TREASURY_ALPHA} ualpha. Send alpha to ${GUILD_VAULT} first.${NC}"
        _bank_back; return
    fi
    read -p "Tokens to mint (base units of ${GUILD_DENOM}): " TOKEN_AMOUNT
    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]] || sx_is_zero "$TOKEN_AMOUNT"; then
        echo -e "${RED}Invalid amount.${NC}"; _bank_back; return
    fi

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Move $(sx_fmt "$ALPHA_AMOUNT") from the guild treasury into collateral"
    echo -e "- Mint $(sx_fmt "$TOKEN_AMOUNT" "$GUILD_DENOM") into the guild vault"
    sx_tx_reset
    sx_tx_add structs guild-bank-mint "$ALPHA_AMOUNT" "$TOKEN_AMOUNT" --guild-id "$GUILD_ID"
    sx_confirm "Confirm this transaction?" && sx_tx_run
    _bank_back
}

function transfer_tokens() {
    print_header
    echo -e "${CYAN}=== TRANSFER TOKENS ===${NC}"
    echo -e "Sends from your whole player account (vault and every address)."
    echo ""
    read -p "Recipient (address or player id): " DESTINATION
    read -p "Amount (e.g. 5guild.${GUILD_ID} or 5000000${GUILD_DENOM}): " AMOUNT
    [ -z "$DESTINATION" ] || [ -z "$AMOUNT" ] && { echo -e "${RED}Recipient and amount are required.${NC}"; _bank_back; return; }
    SX_SIGNER="$PLAYER_ADDRESS"; SX_PLAYER_ID="$PLAYER_ID"
    sx_wallet_load "$PLAYER_ID" && sx_wallet_send "$DESTINATION" "$AMOUNT"
    _bank_back
}

# _bank_min_after_slippage <amount>
function _bank_min_after_slippage() {
    echo "$1 * (10000 - $BANK_SLIPPAGE_BPS) / 10000" | bc
}

function redeem_tokens() {
    print_header
    echo -e "${CYAN}=== REDEEM TOKENS ===${NC}"
    _bank_load
    if sx_is_zero "$TOKEN_SUPPLY" || sx_is_zero "$ALPHA_COLLATERAL"; then
        echo -e "${RED}The bank has no collateral or supply; nothing can be redeemed.${NC}"; _bank_back; return
    fi
    echo -e "${YELLOW}Tokens in your player vault:${NC} ${VAULT_TOKEN} ${GUILD_DENOM}"
    echo ""
    read -p "Tokens to redeem (base units): " TOKEN_AMOUNT
    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]] || sx_is_zero "$TOKEN_AMOUNT"; then
        echo -e "${RED}Invalid amount.${NC}"; _bank_back; return
    fi
    if [ "$(sx_cmp "$TOKEN_AMOUNT" "$VAULT_TOKEN")" = "1" ]; then
        echo -e "${RED}Redeeming uses tokens in your player vault, which holds ${VAULT_TOKEN}.${NC}"
        echo -e "Move tokens into it from the Wallet (consolidate into vault) first."
        _bank_back; return
    fi

    # Same maths as the chain: gross = tokens * collateral / supply; fee rounds up
    GROSS=$(echo "$TOKEN_AMOUNT * $ALPHA_COLLATERAL / $TOKEN_SUPPLY" | bc)
    FEE=$(echo "x = $GROSS * $FEE_OUT; scale=0; if (x > x/1) x/1 + 1 else x/1" | bc -l)
    NET=$(sx_sub "$GROSS" "$FEE")
    MIN_ALPHA=$(_bank_min_after_slippage "$NET")
    [ "$(sx_cmp "$MIN_ALPHA" 1)" = "-1" ] && MIN_ALPHA=1

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Redeem ${TOKEN_AMOUNT} ${GUILD_DENOM}"
    echo -e "- Receive ~$(sx_fmt "$NET") into your player vault (minimum $(sx_fmt "$MIN_ALPHA"))"
    sx_tx_reset
    sx_tx_add structs guild-bank-redeem "${TOKEN_AMOUNT}${GUILD_DENOM}" "$MIN_ALPHA"
    sx_confirm "Confirm this transaction?" && sx_tx_run
    _bank_back
}

function convert_alpha() {
    print_header
    echo -e "${CYAN}=== CONVERT ALPHA INTO ${GUILD_DENOM} ===${NC}"
    _bank_load
    if sx_is_zero "$TOKEN_SUPPLY" || sx_is_zero "$ALPHA_COLLATERAL"; then
        echo -e "${RED}The bank has not been bootstrapped yet (mint first).${NC}"; _bank_back; return
    fi
    echo -e "${YELLOW}Alpha in your player vault:${NC} $(sx_fmt "$VAULT_ALPHA")"
    echo ""
    read -p "Alpha to convert (e.g. 2alpha or 2000000): " RAW
    PARSED=$(sx_parse_amount "$RAW") || { _bank_back; return; }
    ALPHA_AMOUNT=${PARSED% *}
    if [ "$(sx_cmp "$ALPHA_AMOUNT" "$VAULT_ALPHA")" = "1" ]; then
        echo -e "${RED}Converting uses alpha in your player vault ($(sx_fmt "$VAULT_ALPHA")).${NC}"; _bank_back; return
    fi
    FEE=$(echo "x = $ALPHA_AMOUNT * $FEE_IN; scale=0; if (x > x/1) x/1 + 1 else x/1" | bc -l)
    NET=$(sx_sub "$ALPHA_AMOUNT" "$FEE")
    TOKENS=$(echo "$NET * $TOKEN_SUPPLY / $ALPHA_COLLATERAL" | bc)
    MIN_TOKENS=$(_bank_min_after_slippage "$TOKENS")
    [ "$(sx_cmp "$MIN_TOKENS" 1)" = "-1" ] && MIN_TOKENS=1

    echo ""
    echo -e "${YELLOW}You are about to:${NC}"
    echo -e "- Convert $(sx_fmt "$ALPHA_AMOUNT") from your player vault"
    echo -e "- Receive ~${TOKENS} ${GUILD_DENOM} (minimum ${MIN_TOKENS})"
    sx_tx_reset
    sx_tx_add structs guild-bank-convert "$GUILD_ID" "$ALPHA_AMOUNT" "$MIN_TOKENS"
    sx_confirm "Confirm this transaction?" && sx_tx_run
    _bank_back
}

function confiscate_tokens() {
    print_header
    echo -e "${CYAN}=== CONFISCATE AND BURN TOKENS ===${NC}"
    echo ""
    read -p "Target address to confiscate from: " TARGET_ADDRESS
    if [[ -z "$TARGET_ADDRESS" ]]; then
        echo -e "${RED}Target address cannot be empty.${NC}"; _bank_back; return
    fi
    GUILD_DENOM="uguild.${GUILD_ID}"
    TARGET_UTOKEN_BALANCE=$(sx_q bank balance "$TARGET_ADDRESS" "$GUILD_DENOM" | jq -r '.balance.amount // "0"')
    echo -e "${YELLOW}Target token balance:${NC} ${TARGET_UTOKEN_BALANCE} ${GUILD_DENOM}"
    echo ""
    read -p "Tokens to confiscate and burn (base units): " TOKEN_AMOUNT
    if ! [[ "$TOKEN_AMOUNT" =~ ^[0-9]+$ ]] || sx_is_zero "$TOKEN_AMOUNT"; then
        echo -e "${RED}Invalid amount.${NC}"; _bank_back; return
    fi
    if [ "$(sx_cmp "$TOKEN_AMOUNT" "$TARGET_UTOKEN_BALANCE")" = "1" ]; then
        echo -e "${RED}Target only has ${TARGET_UTOKEN_BALANCE} ${GUILD_DENOM}.${NC}"; _bank_back; return
    fi
    echo ""
    echo -e "${YELLOW}You are about to confiscate and burn ${TOKEN_AMOUNT} ${GUILD_DENOM} from ${TARGET_ADDRESS}${NC}"
    sx_tx_reset
    sx_tx_add structs guild-bank-confiscate-and-burn "${TOKEN_AMOUNT}${GUILD_DENOM}" "$TARGET_ADDRESS" --guild-id "$GUILD_ID"
    sx_confirm "Confirm this transaction?" && sx_tx_run
    _bank_back
}
