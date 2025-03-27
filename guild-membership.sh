#!/bin/bash

function membership_menu() {
    print_header

    # Get guild details
    GUILD_JSON=$(structsd ${PARAMS_QUERY} query structs guild ${GUILD_ID})
    GUILD_NAME=$(jq -r '.guild.name' "$GUILD_CONFIG_FILE")

    echo -e "${CYAN}=== MEMBERSHIP MANAGEMENT ===${NC}"
    echo -e "${YELLOW}Guild:${NC} ${GUILD_NAME} (${GUILD_ID})"
    echo ""

    echo -e "${CYAN}=== MENU OPTIONS ===${NC}"
    echo -e "${GREEN}1.${NC} Refresh"
    echo -e "${GREEN}2.${NC} Start Membership Application Invite"
    echo -e "${GREEN}3.${NC} Review Membership Application"
    echo -e "${GREEN}0.${NC} Back to Main Menu"
    echo ""

    read -p "Select an option: " MEMBERSHIP_OPTION

    case $MEMBERSHIP_OPTION in
        1) membership_menu ;;
        2) start_application_invite ;;
        3) review_applications ;;
        0) display_main_screen ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            membership_menu
            ;;
    esac
}

function start_application_invite() {
    print_header
    echo -e "${CYAN}=== START MEMBERSHIP APPLICATION INVITE ===${NC}"
    echo ""

    read -p "Enter Player ID to invite: " TARGET_PLAYER_ID

    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        start_application_invite
        return
    fi

    # Verify player exists
    PLAYER_CHECK=$(structsd ${PARAMS_QUERY} query structs player ${TARGET_PLAYER_ID} 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Player ID ${TARGET_PLAYER_ID} not found.${NC}"
        press_enter_to_continue
        start_application_invite
        return
    fi


    read -p "Confirm sending application invite to this player? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        membership_menu
        return
    fi

    echo -e "${YELLOW}Sending application invite...${NC}"
    structsd ${PARAMS_TX} tx structs guild-membership-invite ${TARGET_PLAYER_ID} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Application invite sent successfully!${NC}"
    press_enter_to_continue
    membership_menu
}

function review_applications() {
    print_header
    echo -e "${CYAN}=== REVIEW MEMBERSHIP APPLICATIONS ===${NC}"
    echo ""

    read -p "Enter Player ID to review: " TARGET_PLAYER_ID

    # Get request details
    REQUESTS_JSON=$(structsd ${PARAMS_QUERY} query structs guild-memerbship-application ${GUILD_ID} ${PLAYER_ID})

    # Check if there are any pending requests
    #TODO FIX
    REQUEST_COUNT=$(echo "$REQUESTS_JSON" | jq -r '.wrongthing.requests | length')
    if [[ "$REQUEST_COUNT" -eq 0 ]]; then
        echo -e "${YELLOW}No pending membership applications found.${NC}"
        press_enter_to_continue
        membership_menu
        return
    fi

    echo -e "${CYAN}Pending Membership Applications:${NC}"
    COLUMN_1="Player ID"
    COLUMN_2="Status"
    COLUMN_3="Join Type"
    COLUMN_4="Proposer"
    COLUMN_5="Substation ID"
    printf "%15s | %30s | %15s | %15s | %15s \n" "${COLUMN_1}" "${COLUMN_2}" "${COLUMN_3}" "${COLUMN_4}" "${COLUMN_5}"
    echo -e "-------------------------------------------------"

    MEMBERSHIP_APPLICATION_STATUS=$(echo "$REQUESTS_JSON" | jq -r ".GuildMembershipApplication.registrationStatus")
    MEMBERSHIP_APPLICATION_JOIN_TYPE=$(echo "$REQUESTS_JSON" | jq -r ".GuildMembershipApplication.joinType")
    MEMBERSHIP_APPLICATION_PROPOSER=$(echo "$REQUESTS_JSON" | jq -r ".GuildMembershipApplication.proposer")
    MEMBERSHIP_APPLICATION_SUBSTATION_ID=$(echo "$REQUESTS_JSON" | jq -r ".GuildMembershipApplication.substationId")

    printf "%15s | %30s | %15s | %15s | %15s \n" "${TARGET_PLAYER_ID}" "${MEMBERSHIP_APPLICATION_STATUS}" "${MEMBERSHIP_APPLICATION_JOIN_TYPE}" "${MEMBERSHIP_APPLICATION_PROPOSER}" "${MEMBERSHIP_APPLICATION_SUBSTATION_ID}"

    echo ""

    echo -e "${CYAN}Options:${NC}"
    echo -e "${GREEN}1.${NC} Accept Application"
    echo -e "${GREEN}2.${NC} Reject Application"
    echo -e "${GREEN}0.${NC} Back to Membership Menu"
    echo ""

    read -p "Select an option: " REVIEW_OPTION

    case $REVIEW_OPTION in
        1) accept_application ;;
        2) reject_application ;;
        0) membership_menu ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            press_enter_to_continue
            review_applications
            ;;
    esac
}

function accept_application() {
    print_header
    echo -e "${CYAN}=== ACCEPT MEMBERSHIP APPLICATION ===${NC}"
    echo ""

    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        accept_application
        return
    fi

    read -p "Confirm accepting this application? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        review_applications
        return
    fi

    echo -e "${YELLOW}Accepting application...${NC}"
    structsd ${PARAMS_TX} tx structs guild-membership-request-approve ${TARGET_PLAYER_ID} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Application accepted successfully!${NC}"
    press_enter_to_continue
    review_applications
}

function reject_application() {
    print_header
    echo -e "${CYAN}=== REJECT MEMBERSHIP APPLICATION ===${NC}"
    echo ""

    if [[ -z "$TARGET_PLAYER_ID" ]]; then
        echo -e "${RED}Player ID cannot be empty.${NC}"
        press_enter_to_continue
        reject_application
        return
    fi

    read -p "Confirm rejecting this application? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        press_enter_to_continue
        review_applications
        return
    fi

    echo -e "${YELLOW}Rejecting application...${NC}"
    # TODO check for MEMBERSHIP_APPLICATION_JOIN_TYPE and only do one of these
    structsd ${PARAMS_TX} tx structs guild-membership-request-reject ${TARGET_PLAYER_ID} --from ${STRUCTS_ACCOUNT}
    structsd ${PARAMS_TX} tx structs guild-membership-request-revoke ${TARGET_PLAYER_ID} --from ${STRUCTS_ACCOUNT}
    sleep $SLEEP_TIME

    echo -e "${GREEN}Application rejected successfully!${NC}"
    press_enter_to_continue
    review_applications
}