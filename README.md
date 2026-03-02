# DG-Discord-Bot

Discord Integration for DG Scripts - Webhooks, Bot API, and Forum Threads

## Features

- **Webhook Logging**: Simple Discord webhook integration
- **Bot API**: Full Discord Bot API support
- **Player Threads**: Automatically creates per-player forum threads
- **Embed Builders**: Pre-built embed creators for various purposes
- **Thread Persistence**: Database-backed thread tracking

## Configuration

Edit `config.lua`:

```lua
Config.discordWebhookUrl = "YOUR_WEBHOOK_URL"
Config.discordBotToken = "YOUR_BOT_TOKEN"
Config.discordForumChannelId = "YOUR_FORUM_CHANNEL_ID"
```

## Exports

### Server Exports

#### Basic Webhook
```lua
exports['dg-discord-bot']:logToDiscord(title, message, color)
exports['dg-discord-bot']:sendDiscordMessage(title, description, color, fields)
```

#### Player Threads
```lua
exports['dg-discord-bot']:getOrCreatePlayerThread(license, playerName, callback)
exports['dg-discord-bot']:postToPlayerThread(license, playerName, embeds)
```

#### Embed Builders
```lua
-- Anti-Cheat & Detections
exports['dg-discord-bot']:buildDetectionEmbed(playerName, reason, weight, score, scoreIncrease, details, identifiers)
exports['dg-discord-bot']:buildPlayerInfoEmbed(playerName, license, identifiers, serverId, ping)
exports['dg-discord-bot']:buildAISuggestionEmbed(suggestion, confidence, context)

-- Moderation
exports['dg-discord-bot']:buildBanEmbed(playerName, adminName, reason, duration, license, identifiers)
exports['dg-discord-bot']:buildKickEmbed(playerName, adminName, reason, serverId)
exports['dg-discord-bot']:buildWarningEmbed(playerName, adminName, warnCount, reason)

-- Player Activity  
exports['dg-discord-bot']:buildConnectionEmbed(playerName, license, identifiers, joining)

-- Admin Actions
exports['dg-discord-bot']:buildAdminActionEmbed(adminName, actionType, targetPlayer, details)
exports['dg-discord-bot']:buildTransactionEmbed(playerName, transactionType, amount, item, adminName)
exports['dg-discord-bot']:buildVehicleSpawnEmbed(playerName, adminName, vehicleModel, plate)

-- Custom Events
exports['dg-discord-bot']:buildServerEventEmbed(eventName, description, details, color)
```

## Usage Examples

### Simple Webhook Logging
```lua
exports['dg-discord-bot']:logToDiscord(
    'Player Joined',
    'John Doe connected to the server',
    65280  -- Green color
)
```

### Ban Notification
```lua
local banEmbed = exports['dg-discord-bot']:buildBanEmbed(
    'John Doe',           -- Player name
    'Admin Smith',        -- Admin name
    'Cheating',          -- Reason
    0,                   -- Duration (0 = permanent)
    'license:abc123',    -- License
    { steamid = 'steam:123', discord = 'discord:456' } -- Identifiers
)

exports['dg-discord-bot']:sendDiscordMessage(nil, nil, nil, nil)
-- Or use the webhook directly
PerformHttpRequest(Config.discordWebhookUrl, function() end, 'POST', 
    json.encode({ embeds = { banEmbed } }), 
    { ['Content-Type'] = 'application/json' }
)
```

### Kick Notification
```lua
local kickEmbed = exports['dg-discord-bot']:buildKickEmbed(
    'John Doe',      -- Player name
    'Admin Smith',   -- Admin name
    'AFK',          -- Reason
    42              -- Server ID
)

-- Send via webhook (embed is already built, just wrap it)
exports['dg-discord-bot']:logToDiscord(nil, nil, nil) -- Use direct HTTP for embeds
```

### Player Connection Log
```lua
-- Player joined
local joinEmbed = exports['dg-discord-bot']:buildConnectionEmbed(
    'John Doe',
    'license:abc123',
    { steamid = 'steam:123', discord = 'discord:456' },
    true  -- true = joining, false = leaving
)

-- Player left
local leaveEmbed = exports['dg-discord-bot']:buildConnectionEmbed(
    'John Doe',
    'license:abc123',
    { steamid = 'steam:123', discord = 'discord:456' },
    false
)
```

### Admin Action Logging
```lua
local actionEmbed = exports['dg-discord-bot']:buildAdminActionEmbed(
    'Admin Smith',           -- Admin name
    'give_item',            -- Action type
    'John Doe',             -- Target player
    'Gave 50x bandage'      -- Details
)
```

### Economy Transaction
```lua
-- Item transaction
local itemEmbed = exports['dg-discord-bot']:buildTransactionEmbed(
    'John Doe',      -- Player name
    'give',          -- Type: 'give' or 'remove'
    50,              -- Amount
    'bandage',       -- Item name
    'Admin Smith'    -- Admin name
)

-- Money transaction
local moneyEmbed = exports['dg-discord-bot']:buildTransactionEmbed(
    'John Doe',
    'remove',
    5000,
    nil,             -- nil = money instead of item
    'System'
)
```

### Warning System
```lua
local warnEmbed = exports['dg-discord-bot']:buildWarningEmbed(
    'John Doe',      -- Player name
    'Admin Smith',   -- Admin who issued warning
    2,               -- Total warning count
    'Combat logging' -- Reason
)
```

### Vehicle Spawn Log
```lua
local vehEmbed = exports['dg-discord-bot']:buildVehicleSpawnEmbed(
    'John Doe',      -- Player name
    'Admin Smith',   -- Admin name
    'adder',         -- Vehicle model
    'ADMIN01'        -- Plate
)
```

### AI Suggestion (for advanced anti-cheat)
```lua
local aiEmbed = exports['dg-discord-bot']:buildAISuggestionEmbed(
    'Player movement patterns suggest aimbot usage',  -- Suggestion
    0.87,                                             -- Confidence (0-1)
    'Analyzed 150 shots with 89% headshot rate'      -- Context
)
```

### Custom Server Event
```lua
local eventEmbed = exports['dg-discord-bot']:buildServerEventEmbed(
    'HeistCompleted',                    -- Event name
    'Pacific Standard Bank was robbed',  -- Description
    {                                    -- Details (optional)
        ['Reward'] = '$1,500,000',
        ['Participants'] = '4 players',
        ['Duration'] = '32 minutes'
    },
    0x00FF00  -- Color (green)
)
```

### Create Player Thread & Post Detection
```lua
local license = exports['dg-bridge']:getLicense(source)
local playerName = GetPlayerName(source)
local identifiers = exports['dg-bridge']:getAllIdentifiers(source)

-- Build detection embed
local detectionEmbed = exports['dg-discord-bot']:buildDetectionEmbed(
    playerName,
    'speedhack',
    'critical',
    6,
    2,
    { speed = '250 km/h', location = 'Los Santos' },
    identifiers
)

-- Post to player's dedicated thread
exports['dg-discord-bot']:postToPlayerThread(license, playerName, { detectionEmbed })
```

## Database

Creates the following table:
```sql
CREATE TABLE dg_discord_threads (
    license VARCHAR(64) PRIMARY KEY,
    thread_id VARCHAR(32) NOT NULL,
    player_name VARCHAR(128),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)
```

## Installation

1. Place `dg-discord-bot` in your resources folder
2. Configure Discord settings in `config.lua`
3. Add to `server.cfg`:
```
ensure dg-discord-bot
```

## Discord Setup

### Webhook Setup
1. Open Discord Server Settings
2. Go to Integrations > Webhooks
3. Click "New Webhook"
4. Copy the URL to `config.lua`

### Bot Token Setup
1. Go to https://discord.com/developers/applications
2. Create new application
3. Go to "Bot" section
4. Copy token to `config.lua`
5. Enable required intents (Server Members, Message Content)
6. Invite bot to your server

### Forum Channel Setup
1. Create a forum channel in Discord
2. Right-click > Copy ID (requires Developer Mode enabled)
3. Paste ID in `config.lua`
4. Ensure bot has permissions: Create Posts, Send Messages, Embed Links

## Dependencies

- `oxmysql` - For database operations
