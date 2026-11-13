#!/bin/bash

# Guild Administration Tool for Structs
# Version 1.0

# Constants
CONFIG_DIR="$HOME/.structs-guild-admin"
CONFIG_FILE="$CONFIG_DIR/config.json"
GUILD_CONFIG_FILE="$CONFIG_DIR/guild.json"
SLEEP_TIME=6
PARAMS_TX=" --gas auto --yes=true "
PARAMS_QUERY=" --output json "
PARAMS_KEYS=" --output json "

# Colors for better UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Source all module files (relative to this script, so it runs from anywhere)
GUILD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$GUILD_SCRIPT_DIR/structs-lib.sh"
source "$GUILD_SCRIPT_DIR/structs-wallet.sh"
source "$GUILD_SCRIPT_DIR/guild-common.sh"
source "$GUILD_SCRIPT_DIR/guild-setup.sh"
source "$GUILD_SCRIPT_DIR/guild-energy-grid.sh"
source "$GUILD_SCRIPT_DIR/guild-central-bank.sh"
source "$GUILD_SCRIPT_DIR/guild-membership.sh"
source "$GUILD_SCRIPT_DIR/guild-config.sh"
source "$GUILD_SCRIPT_DIR/guild-permission.sh"

# Initialize the tool
function initialize() {
    print_header
    echo -e "${CYAN}Initializing Structs Guild Administration Tool...${NC}"
    echo ""

    # Load configuration
    load_config

    # Load guild configuration
    load_guild_config

    # Display main screen
    display_main_screen
}

# Start the tool
initialize

