#!/bin/bash

# Structs Guild Chain Monitor
# Automatically monitors chain changes and recreates guild infrastructure
# Version 1.0

set -euo pipefail

# Script configuration
SCRIPT_NAME="automate-guild-chain-monitor.sh"
SCRIPT_VERSION="1.0"
SLEEP_TIME=6
PARAMS_TX=" --gas auto --yes=true "
PARAMS_QUERY=" --output json "
PARAMS_KEYS=" --output json "

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
DEFAULT_MONITOR_INTERVAL=300
DEFAULT_LOG_LEVEL="INFO"
DEFAULT_LOG_FILE="/var/log/guild-monitor.log"
DEFAULT_PID_FILE="/var/run/guild-monitor.pid"

# Load environment variables with defaults
MONITOR_INTERVAL=${MONITOR_INTERVAL:-$DEFAULT_MONITOR_INTERVAL}
LOG_LEVEL=${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}
LOG_FILE=${LOG_FILE:-$DEFAULT_LOG_FILE}
PID_FILE=${PID_FILE:-$DEFAULT_PID_FILE}

# Required environment variables
REQUIRED_VARS=(
    "STRUCTS_ACCOUNT_NAME"
    "GUILD_NAME"
    "GUILD_DESCRIPTION"
    "GUILD_TAG"
    "GUILD_LOGO"
    "GUILD_WEBSITE"
    "GUILD_TOKEN_NAME"
    "GUILD_TOKEN_SMALLEST_VALUE_NAME"
    "GUILD_SOCIAL_DISCORD_CONTACT"
    "GUILD_BASE_ENERGY"
)

# Global variables
CURRENT_CHAIN_ID=""
LAST_CHAIN_ID=""
PLAYER_ADDRESS=""
PLAYER_ID=""
GUILD_ID=""
IS_RUNNING=true

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check log level
    case $LOG_LEVEL in
        "DEBUG")
            level_filter="DEBUG|INFO|WARN|ERROR"
            ;;
        "INFO")
            level_filter="INFO|WARN|ERROR"
            ;;
        "WARN")
            level_filter="WARN|ERROR"
            ;;
        "ERROR")
            level_filter="ERROR"
            ;;
        *)
            level_filter="INFO|WARN|ERROR"
            ;;
    esac
    
    if [[ $level =~ $level_filter ]]; then
        echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    fi
}

log_debug() { log "DEBUG" "$*"; }
log_info() { log "INFO" "$*"; }
log_warn() { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }

# Validation functions
validate_environment() {
    log_info "Validating environment configuration..."
    
    local missing_vars=()
    
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi
    
    # Validate account exists
    if ! structsd keys list --output json | jq -e ".[] | select(.name == \"$STRUCTS_ACCOUNT_NAME\")" > /dev/null 2>&1; then
        log_error "Account '$STRUCTS_ACCOUNT_NAME' not found in structsd keys"
        exit 1
    fi
    
    log_info "Environment validation passed"
}

# Chain monitoring functions
get_current_chain_id() {
    local chain_info
    chain_info=$(structsd $PARAMS_QUERY status 2>/dev/null || echo "")
    
    if [[ -n "$chain_info" ]]; then
        echo "$chain_info" | jq -r '.node_info.network' 2>/dev/null || echo ""
    else
        echo ""
    fi
}


# Store guild ID in $STRUCTS_PATH/status/guild_${chain_id}

# If $STRUCTS_PATH/status/guild_${chain_id} doesn't exist

  # Check to see if the guild_admin account exists
    #  create it with the mnemonic

  # Do a lookup, try to reverse engineer based on guild_admin account

  # If no guild ID still,
    # create guild
    # write to that file



check_chain_change() {
    local current_chain
    current_chain=$(get_current_chain_id)
    
    if [[ -z "$current_chain" ]]; then
        log_warn "Unable to query current chain ID"
        return 1
    fi
    
    if [[ "$current_chain" != "$LAST_CHAIN_ID" ]]; then
        log_info "Chain change detected: $LAST_CHAIN_ID -> $current_chain"
        CURRENT_CHAIN_ID="$current_chain"
        return 0
    fi
    
    return 1
}

# Guild creation functions
get_player_info() {
    log_debug "Getting player information..."
    
    PLAYER_ADDRESS=$(structsd $PARAMS_KEYS keys show $STRUCTS_ACCOUNT_NAME | jq -r .address)
    if [[ -z "$PLAYER_ADDRESS" || "$PLAYER_ADDRESS" == "null" ]]; then
        log_error "Failed to get player address"
        return 1
    fi
    
    PLAYER_ID=$(structsd $PARAMS_QUERY query structs address $PLAYER_ADDRESS | jq -r .playerId)
    if [[ -z "$PLAYER_ID" || "$PLAYER_ID" == "null" ]]; then
        log_error "Failed to get player ID"
        return 1
    fi
    
    log_info "Player Address: $PLAYER_ADDRESS, Player ID: $PLAYER_ID"
    return 0
}

create_allocation() {
    log_info "Creating allocation for player $PLAYER_ID..."
    
    local player_capacity
    player_capacity=$(structsd $PARAMS_QUERY query structs player $PLAYER_ID | jq -r '.gridAttributes.capacity')
    
    if [[ -z "$player_capacity" || "$player_capacity" == "null" ]]; then
        log_error "Failed to get player capacity"
        return 1
    fi
    
    structsd $PARAMS_TX tx structs allocation-create $PLAYER_ID $player_capacity --allocation-type automated --from $STRUCTS_ACCOUNT_NAME
    sleep $SLEEP_TIME
    
    log_info "Allocation created successfully"
    return 0
}

get_allocation_id() {
    structsd query structs allocation-all-by-source $PLAYER_ID --output json | jq -r '.Allocation[0].id'
}

create_substation() {
    local allocation_id=$1
    log_info "Creating substation for allocation $allocation_id..."
    
    structsd $PARAMS_TX tx structs substation-create $PLAYER_ID $allocation_id --from $STRUCTS_ACCOUNT_NAME
    sleep $SLEEP_TIME
    
    log_info "Substation created successfully"
    return 0
}

get_substation_id() {
    local allocation_id=$1
    structsd $PARAMS_QUERY query structs allocation $allocation_id | jq -r ".Allocation.destinationId"
}

create_guild() {
    local substation_id=$1
    log_info "Creating guild with substation $substation_id..."
    
    structsd $PARAMS_TX tx structs guild-create "temp.endpoint.com" $substation_id --from $STRUCTS_ACCOUNT_NAME
    sleep $SLEEP_TIME
    
    log_info "Guild created successfully"
    return 0
}

get_guild_id() {
    structsd $PARAMS_QUERY query structs player $PLAYER_ID | jq -r '.Player.guildId'
}

upload_guild_metadata() {
    local guild_id=$1
    log_info "Uploading guild metadata for guild $guild_id..."
    
    # Create guild JSON from environment variables
    local guild_json
    guild_json=$(jq -n \
        --arg id "$guild_id" \
        --arg name "$GUILD_NAME" \
        --arg description "$GUILD_DESCRIPTION" \
        --arg tag "$GUILD_TAG" \
        --arg logo "$GUILD_LOGO" \
        --arg website "$GUILD_WEBSITE" \
        --arg discordContact "$GUILD_SOCIAL_DISCORD_CONTACT" \
        --arg coin "$GUILD_TOKEN_NAME" \
        --arg smallestCoin "$GUILD_TOKEN_SMALLEST_VALUE_NAME" \
        --arg baseEnergy "$GUILD_BASE_ENERGY" \
        '{ guild: { id: $id, name: $name, description: $description, tag: $tag, baseEnergy: $baseEnergy, logo: $logo, website: $website, socials: { discordContact: $discordContact }, denom: {"6": $coin, "0": $smallestCoin } } }')
    
    # Create temporary file
    local temp_file
    temp_file=$(mktemp)
    echo "$guild_json" > "$temp_file"
    
    # Upload to paste service
    local upload_url
    upload_url=$(curl --upload-file "$temp_file" 'https://paste.c-net.org/' 2>/dev/null)
    
    # Clean up temp file
    rm -f "$temp_file"
    
    if [[ -z "$upload_url" ]]; then
        log_error "Failed to upload guild metadata"
        return 1
    fi
    
    # Update guild endpoint
    structsd $PARAMS_TX tx structs guild-update-endpoint $guild_id "$upload_url" --from $STRUCTS_ACCOUNT_NAME
    sleep $SLEEP_TIME
    
    log_info "Guild metadata uploaded and endpoint updated: $upload_url"
    return 0
}

recreate_guild() {
    log_info "Starting guild recreation process..."
    
    # Get player information
    if ! get_player_info; then
        log_error "Failed to get player information"
        return 1
    fi
    
    # Check for existing allocation
    local allocation_id
    allocation_id=$(get_allocation_id)
    
    if [[ -z "$allocation_id" || "$allocation_id" == "null" ]]; then
        log_info "No allocation found, creating new allocation..."
        if ! create_allocation; then
            log_error "Failed to create allocation"
            return 1
        fi
        allocation_id=$(get_allocation_id)
    else
        log_info "Using existing allocation: $allocation_id"
    fi
    
    # Check for existing substation
    local substation_id
    substation_id=$(get_substation_id "$allocation_id")
    
    if [[ -z "$substation_id" || "$substation_id" == "null" ]]; then
        log_info "No substation found, creating new substation..."
        if ! create_substation "$allocation_id"; then
            log_error "Failed to create substation"
            return 1
        fi
        substation_id=$(get_substation_id "$allocation_id")
    else
        log_info "Using existing substation: $substation_id"
    fi
    
    # Check for existing guild
    local guild_id
    guild_id=$(get_guild_id)
    
    if [[ -z "$guild_id" || "$guild_id" == "null" ]]; then
        log_info "No guild found, creating new guild..."
        if ! create_guild "$substation_id"; then
            log_error "Failed to create guild"
            return 1
        fi
        guild_id=$(get_guild_id)
    else
        log_info "Using existing guild: $guild_id"
    fi
    
    if [[ -z "$guild_id" || "$guild_id" == "null" ]]; then
        log_error "Failed to get guild ID after creation"
        return 1
    fi
    
    GUILD_ID="$guild_id"
    
    # Upload guild metadata
    if ! upload_guild_metadata "$guild_id"; then
        log_error "Failed to upload guild metadata"
        return 1
    fi
    
    log_info "Guild recreation completed successfully. Guild ID: $guild_id"
    return 0
}

# Signal handling
cleanup() {
    log_info "Shutting down guild monitor..."
    IS_RUNNING=false
    
    if [[ -f "$PID_FILE" ]]; then
        rm -f "$PID_FILE"
    fi
    
    exit 0
}

# Main monitoring loop
monitor_loop() {
    log_info "Starting guild chain monitoring..."
    log_info "Monitor interval: ${MONITOR_INTERVAL}s"
    log_info "Account: $STRUCTS_ACCOUNT_NAME"
    
    # Get initial chain ID
    LAST_CHAIN_ID=$(get_current_chain_id)
    if [[ -n "$LAST_CHAIN_ID" ]]; then
        log_info "Initial chain ID: $LAST_CHAIN_ID"
    else
        log_warn "Unable to get initial chain ID"
    fi
    
    # Initial guild setup
    log_info "Performing initial guild setup..."
    if ! recreate_guild; then
        log_error "Initial guild setup failed"
        exit 1
    fi
    
    # Main monitoring loop
    while $IS_RUNNING; do
        log_debug "Checking for chain changes..."
        
        if check_chain_change; then
            log_info "Chain change detected, recreating guild..."
            
            if recreate_guild; then
                log_info "Guild recreation completed successfully"
                LAST_CHAIN_ID="$CURRENT_CHAIN_ID"
            else
                log_error "Guild recreation failed"
            fi
        fi
        
        log_debug "Sleeping for ${MONITOR_INTERVAL} seconds..."
        sleep $MONITOR_INTERVAL
    done
}

# Main function
main() {
    # Set up signal handlers
    trap cleanup SIGINT SIGTERM
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Create PID file
    echo $$ > "$PID_FILE"
    
    # Validate environment
    validate_environment
    
    # Start monitoring
    monitor_loop
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
