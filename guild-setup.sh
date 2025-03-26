#!/bin/bash

function load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        STRUCTS_ACCOUNT=$(jq -r '.account_name' "$CONFIG_FILE")
        echo -e "${GREEN}Loaded configuration for account: ${STRUCTS_ACCOUNT}${NC}"
    else
        setup_config
    fi
}

function setup_config() {
    print_header
    echo -e "${YELLOW}No configuration found. Let's set up your account.${NC}"
    echo ""

    # Get list of available accounts
    ACCOUNTS_JSON=$(structsd keys list --output json)
    ACCOUNT_COUNT=$(echo "$ACCOUNTS_JSON" | jq length)

    if [ "$ACCOUNT_COUNT" -eq 0 ]; then
        echo -e "${RED}No accounts found. Please create an account first.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Available accounts:${NC}"
    echo ""

    for ((i=0; i<$ACCOUNT_COUNT; i++)); do
        ACCOUNT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].name")
        ACCOUNT_ADDRESS=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].address")
        echo -e "${GREEN}$((i+1)).${NC} ${ACCOUNT_NAME} (${ACCOUNT_ADDRESS})"
    done

    echo ""
    read -p "Select an account (1-$ACCOUNT_COUNT): " ACCOUNT_OPTION

    if ! [[ "$ACCOUNT_OPTION" =~ ^[0-9]+$ ]] || [ "$ACCOUNT_OPTION" -lt 1 ] || [ "$ACCOUNT_OPTION" -gt "$ACCOUNT_COUNT" ]; then
        echo -e "${RED}Invalid option. Please try again.${NC}"
        press_enter_to_continue
        setup_config
        return
    fi

    STRUCTS_ACCOUNT=$(echo "$ACCOUNTS_JSON" | jq -r ".[$(($ACCOUNT_OPTION-1))].name")
    echo -e "${GREEN}Selected account: ${STRUCTS_ACCOUNT_ADDRESS}${NC}"

    # Save configuration
    mkdir -p "$CONFIG_DIR"
    echo "{\"account_name\": \"$STRUCTS_ACCOUNT\"}" > "$CONFIG_FILE"
    echo -e "${GREEN}Configuration saved.${NC}"

    press_enter_to_continue
}

function load_guild_config() {
    if [ -f "$GUILD_CONFIG_FILE" ]; then
        GUILD_ID=$(jq -r '.guild.id' "$GUILD_CONFIG_FILE")
        echo -e "${GREEN}Loaded guild configuration for guild ID: ${GUILD_ID}${NC}"
    else
        check_existing_guild
    fi
}

function check_existing_guild() {
    print_header
    echo -e "${YELLOW}No guild configuration found. Checking for existing guild...${NC}"
    echo ""

    # Get player address and ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    # Check if player has a guild
    GUILDS_JSON=$(structsd ${PARAMS_QUERY} query structs guild-all | jq -r '.Guild[]')

    if [ -z "$GUILDS_JSON" ]; then
        echo -e "${YELLOW}No guilds found. Starting guild setup process...${NC}"
        setup_guild
        return
    fi

    # Find guilds owned by the player
    OWNED_GUILDS=()

    while read -r GUILD; do
        GUILD_ID=$(echo "$GUILD" | jq -r '.id')
        GUILD_OWNER_ID=$(echo "$GUILD" | jq -r '.ownerId')

        if [ "$GUILD_OWNER_ID" == "$PLAYER_ID" ]; then
            OWNED_GUILDS+=("$GUILD")
        fi
    done <<< "$(echo "$GUILDS_JSON" | jq -s '.[]')"

    if [ ${#OWNED_GUILDS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No guilds owned by this player. Starting guild setup process...${NC}"
        setup_guild
        return
    fi

    echo -e "${GREEN}Found ${#OWNED_GUILDS[@]} guild(s) owned by this player.${NC}"
    echo ""

    if [ ${#OWNED_GUILDS[@]} -eq 1 ]; then
        # Only one guild, use it
        GUILD_ID=$(echo "${OWNED_GUILDS[0]}" | jq -r '.id')
        echo -e "${GREEN}Using guild ID: ${GUILD_ID}${NC}"
        setup_guild_metadata
    else
        # Multiple guilds, let user choose
        echo "Select a guild:"
        echo ""

        for ((i=0; i<${#OWNED_GUILDS[@]}; i++)); do
            GUILD_ID=$(echo "${OWNED_GUILDS[$i]}" | jq -r '.id')
            echo -e "${GREEN}$((i+1)).${NC} Guild ID: ${GUILD_ID}"
        done

        echo ""
        read -p "Select a guild (1-${#OWNED_GUILDS[@]}): " GUILD_OPTION

        if ! [[ "$GUILD_OPTION" =~ ^[0-9]+$ ]] || [ "$GUILD_OPTION" -lt 1 ] || [ "$GUILD_OPTION" -gt "${#OWNED_GUILDS[@]}" ]; then
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            check_existing_guild
            return
        fi

        GUILD_ID=$(echo "${OWNED_GUILDS[$(($GUILD_OPTION-1))]}" | jq -r '.id')
        echo -e "${GREEN}Selected guild ID: ${GUILD_ID}${NC}"
        setup_guild_metadata
    fi
}

function setup_guild() {
    print_header
    echo -e "${CYAN}=== GUILD SETUP ===${NC}"
    echo ""

    # Get player address and ID
    PLAYER_ADDRESS=$(structsd ${PARAMS_KEYS} keys show ${STRUCTS_ACCOUNT} | jq -r .address)
    PLAYER_ID=$(structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId)

    echo -e "${YELLOW}Checking current Player available capacity...${NC}"
    PLAYER_CAPACITY=$(structsd ${PARAMS_QUERY} query structs player ${PLAYER_ID} | jq -r '.Player.gridAttributes.capacity')
    echo -e "${GREEN}Player capacity: ${PLAYER_CAPACITY}${NC}"

    echo -e "${YELLOW}Checking for existing allocation...${NC}"
    ALLOCATION_ID=$(structsd query structs allocation-all-by-source ${PLAYER_ID} --output json | jq -r '.Allocation[0].id')

    if [[ -z "${ALLOCATION_ID}" ]] || [ "$ALLOCATION_ID" == "null" ]; then
        echo -e "${YELLOW}Creating a new allocation...${NC}"
        structsd ${PARAMS_TX} tx structs allocation-create ${PLAYER_ID} ${PLAYER_CAPACITY} --allocation-type automated --from ${STRUCTS_ACCOUNT}
        sleep $SLEEP_TIME

        ALLOCATION_ID=$(structsd query structs allocation-all-by-source ${PLAYER_ID} --output json | jq -r '.Allocation[0].id')
    else
        echo -e "${GREEN}Allocation already found: ${ALLOCATION_ID}${NC}"
    fi

    echo -e "${YELLOW}Checking for substation...${NC}"
    SUBSTATION_ID=$(structsd ${PARAMS_QUERY} query structs allocation ${ALLOCATION_ID} | jq -r ".Allocation.destinationId")

    if [[ -z "${SUBSTATION_ID}" ]] || [ "$SUBSTATION_ID" == "null" ]; then
        echo -e "${YELLOW}Creating a new substation...${NC}"
        structsd ${PARAMS_TX} tx structs substation-create ${PLAYER_ID} ${ALLOCATION_ID} --from ${STRUCTS_ACCOUNT}
        sleep $SLEEP_TIME

        SUBSTATION_ID=$(structsd ${PARAMS_QUERY} query structs allocation ${ALLOCATION_ID} | jq -r ".Allocation.destinationId")
    else
        echo -e "${GREEN}Substation already found: ${SUBSTATION_ID}${NC}"
    fi

    echo -e "${YELLOW}Checking if guild already exists...${NC}"
    GUILD_ID=$(structsd ${PARAMS_QUERY} query structs player ${PLAYER_ID} | jq -r '.Player.guildId')

    if [[ -z "${GUILD_ID}" ]] || [ "$GUILD_ID" == "null" ]; then
        echo -e "${YELLOW}Creating a new guild...${NC}"
        structsd ${PARAMS_TX} tx structs guild-create "temp.endpoint.com" ${SUBSTATION_ID} --from ${STRUCTS_ACCOUNT}
        sleep $SLEEP_TIME

        GUILD_ID=$(structsd ${PARAMS_QUERY} query structs player ${PLAYER_ID} | jq -r '.Player.guildId')
    else
        echo -e "${GREEN}Guild already found: ${GUILD_ID}${NC}"
    fi

    if [[ -z "${GUILD_ID}" ]] || [ "$GUILD_ID" == "null" ]; then
        echo -e "${RED}Problem during guild creation!${NC}"
        press_enter_to_continue
        exit 1
    fi

    setup_guild_metadata
}

function setup_guild_metadata() {
    print_header
    echo -e "${CYAN}=== GUILD METADATA SETUP ===${NC}"
    echo ""

    echo -e "${YELLOW}Please provide details about your guild:${NC}"
    echo ""

    read -p "Guild Name: " GUILD_NAME
    read -p "Guild Description: " GUILD_DESCRIPTION
    read -p "Guild Tag (1-3 characters): " GUILD_TAG
    read -p "Guild Logo URL: " GUILD_LOGO
    read -p "Guild Website URL: " GUILD_WEBSITE
    read -p "Guild Token Name (e.g., gld): " GUILD_TOKEN_NAME
    read -p "Guild Token Smallest Unit Name (e.g., ugld): " GUILD_TOKEN_SMALLEST_VALUE_NAME
    read -p "Discord Contact: " GUILD_SOCIAL_DISCORD_CONTACT

    # Create guild JSON
    GUILD_JSON=$( jq -n \
                  --arg id "$GUILD_ID" \
                  --arg name "$GUILD_NAME" \
                  --arg description "$GUILD_DESCRIPTION" \
                  --arg tag "$GUILD_TAG" \
                  --arg logo "$GUILD_LOGO" \
                  --arg website "$GUILD_WEBSITE" \
                  --arg discordContact "$GUILD_SOCIAL_DISCORD_CONTACT" \
                  --arg coin "$GUILD_TOKEN_NAME" \
                  --arg smallestCoin "$GUILD_TOKEN_SMALLEST_VALUE_NAME" \
                  '{ guild: { id: $id, name: $name, description: $description, tag: $tag, logo: $logo, website: $website, socials: { discord_contact: $discordContact }, denom: {"6": $coin, "0": $smallestCoin } } }' )

    # Save guild metadata
    echo "$GUILD_JSON" > "$GUILD_CONFIG_FILE"
    echo -e "${GREEN}Guild metadata saved.${NC}"

    # Upload to paste service
    echo "$GUILD_JSON" > "$GUILD_CONFIG_FILE.tmp"
    UPLOAD_URL=$(curl --upload-file "$GUILD_CONFIG_FILE.tmp" 'https://paste.c-net.org/')

    if [ -n "$UPLOAD_URL" ]; then
        echo -e "${YELLOW}Updating guild endpoint...${NC}"
        structsd ${PARAMS_TX} tx structs guild-update-endpoint ${GUILD_ID} "${UPLOAD_URL}" --from ${STRUCTS_ACCOUNT}
        sleep $SLEEP_TIME
        echo -e "${GREEN}Guild endpoint updated successfully!${NC}"
    else
        echo -e "${RED}Failed to upload guild metadata.${NC}"
    fi

    rm -f "$GUILD_CONFIG_FILE.tmp"
    press_enter_to_continue
}