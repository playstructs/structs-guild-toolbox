SLEEP=6

# Probably don't change
# Unless you used a non-standard wallet or home directory
PARAMS_TX=" --gas auto --yes=true "
echo "${PARAMS_TX}"
PARAMS_QUERY="--output json"
echo "${PARAMS_QUERY}"
PARAMS_KEYS=" --output json"
echo "${PARAMS_KEYS}"


# Ask for Validator Account Name
echo "What is the name of the structsd account for your validator? (as in --from ______):"
read -r VALIDATOR_ACCOUNT_NAME


# Load the Player ID
PLAYER_ADDRESS=`structsd ${PARAMS_KEYS} keys show ${VALIDATOR_ACCOUNT_NAME} | jq -r .address`
echo "${PLAYER_ADDRESS}"

PLAYER_ID=`structsd ${PARAMS_QUERY} query structs address ${PLAYER_ADDRESS} | jq -r .playerId`
echo "${PLAYER_ID}"


# Get the Guild ID
GUILD_ID=`structsd ${PARAMS_QUERY} query structs player ${PLAYER_ID} | jq -r .Player.guildId`
echo "${GUILD_ID}"

echo "Please provide as much or as little details about your Guild..."

# Create the Guild Definition
echo "Guild Name:"
read -r GUILD_NAME

echo "Guild Description:"
read -r GUILD_DESCRIPTION

echo "Guild Tag (a 1-3 character gamer tag):"
read -r GUILD_TAG

echo "A URL to a Guild Logo:"
read -r GUILD_LOGO

echo "Primary domain for the Guild:"
read -r GUILD_DOMAIN

echo "A URL to a Guild Website:"
read -r GUILD_WEBSITE

echo "What is the ticker for your Guild Currency? (Ex gld):"
read -r GUILD_TOKEN_NAME

echo "What is the smallest unit of your Guild Currency called? (Ex dst):"
read -r GUILD_TOKEN_SMALLEST_VALUE_NAME


echo "Provide a public discord username contact (or don't, nbd):"
read -r GUILD_SOCIAL_DISCORD_CONTACT

GUILD_JSON=$( jq -n \
                  --arg id "$GUILD_ID" \
                  --arg name "$GUILD_NAME" \
                  --arg description "$GUILD_DESCRIPTION" \
                  --arg tag "$GUILD_TAG" \
                  --arg logo "$GUILD_LOGO" \
                  --arg website "$GUILD_WEBSITE" \
                  --arg domain "$GUILD_DOMAIN" \
                  --arg bluesky "$GUILD_SOCIAL_BLUESKY" \
                  --arg facebook "$GUILD_SOCIAL_FACEBOOK" \
                  --arg farcaster "$GUILD_SOCIAL_FARCASTER" \
                  --arg instagram "$GUILD_SOCIAL_INSTAGRAM" \
                  --arg twitch "$GUILD_SOCIAL_TWITCH" \
                  --arg x "$GUILD_SOCIAL_X" \
                  --arg youtube "$GUILD_SOCIAL_YOUTUBE" \
                  --arg discordContact "$GUILD_SOCIAL_DISCORD_CONTACT" \
                  --arg discordServer "$GUILD_SOCIAL_DISCORD_SERVER" \
                  --arg telegramContact "$GUILD_SOCIAL_TELEGRAM_CONTACT" \
                  --arg telegramChannel "$GUILD_SOCIAL_TELEGRAM_CHANNEL" \
                  --arg coin "$GUILD_TOKEN_NAME" \
                  --arg smallestCoin "$GUILD_TOKEN_SMALLEST_VALUE_NAME" \
                  --arg guildApi "$GUILD_SERVICE_GUILD_API" \
                  --arg reactorApi "$GUILD_SERVICE_REACTOR_API" \
                  --arg explorer "$GUILD_SERVIVCE_EXPLORER" \
								'{ guild: { id: $id, name: $name, description: $description, tag: $tag, logo: $logo, domain: $domain, website: $website, socials: { bluesky: $bluesky, facebook: $facebook, farcaster: $farcaster, instagram: $instagram, twitch: $twitch, x: $x, youtube: $youtube, discord_contact: $discordContact, discord_server: $discordServer, telegram_contact: $telegramContact, telegram_channel: $telegramChannel }, denom: {"6": $coin, "0": $smallestCoin }, services:{ guild_api: $guildApi, reactorApi: $reactorApi, explorer: $explorer  } } }' )


echo $GUILD_JSON
echo "Details about to be updated.. press enter to continue"
read -r PAUSE_VAR

echo $GUILD_JSON > guild.json.tmp
UPLOAD_URL=$(curl --upload-file 'guild.json.tmp' 'https://paste.c-net.org/')
sleep $SLEEP

echo "Updating Endpoint..."
structsd ${PARAMS_TX} tx structs guild-update-endpoint ${GUILD_ID} "${UPLOAD_URL}"  --from ${VALIDATOR_ACCOUNT_NAME}
sleep $SLEEP

echo "Guild Creation Complete"