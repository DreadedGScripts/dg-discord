# DG-Discord-Bot

Discord integration resource for DG scripts.

- Resource: `dg-discord-bot`
- Version: `1.0.0`
- Dependency: `oxmysql`

## What It Does

- Sends webhook embeds/messages to Discord.
- Uses Discord Bot REST API for forum thread posting.
- Creates and reuses per-player forum threads.
- Stores thread mapping in MySQL (`dg_discord_threads`).
- Provides reusable embed builder exports for moderation/detection logs.

## Configuration

Set values in `config.lua`:

- `Config.discordWebhookUrl`
- `Config.discordBotToken`
- `Config.discordForumChannelId`
- `Config.enableWebhook`
- `Config.enableBotAPI`
- `Config.enablePlayerThreads`

If placeholders are left in place, related features are skipped and warning logs are printed.

## Exports

This list matches current `fxmanifest.lua` and server implementation.

- `logToDiscord`
- `sendDiscordMessage`
- `postToPlayerThread`
- `getOrCreatePlayerThread`
- `buildDetectionEmbed`
- `buildPlayerInfoEmbed`
- `buildBanEmbed`
- `buildKickEmbed`
- `buildConnectionEmbed`
- `buildAdminActionEmbed`
- `buildWarningEmbed`
- `buildAISuggestionEmbed`
- `buildTransactionEmbed`
- `buildVehicleSpawnEmbed`
- `buildServerEventEmbed`

## Database

Auto-created table:

```sql
CREATE TABLE IF NOT EXISTS dg_discord_threads (
    license VARCHAR(64) PRIMARY KEY,
    thread_id VARCHAR(32) NOT NULL,
    player_name VARCHAR(128),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)
```

## Behavior Notes

- Thread IDs are cached in memory and persisted in MySQL.
- If a thread is deleted (HTTP 404), the cache/DB mapping is cleared and recreated automatically on next post.
- Integration is REST-based (webhook + Discord HTTP API).
- Custom Discord presence text is not managed by this resource.

## Installation

Add to `server.cfg`:

```cfg
ensure oxmysql
ensure dg-discord-bot
```

## Minimal Usage

```lua
-- Webhook message
exports['dg-discord-bot']:logToDiscord('Server Event', 'DG Discord Bot is online', 5763719)

-- Post embed to player thread
local embed = exports['dg-discord-bot']:buildDetectionEmbed(
    'PlayerName',
    'speedhack',
    'critical',
    6,
    2,
    { speed = '250 km/h' },
    { discord = 'discord:123', steamid = 'steam:abc' }
)

exports['dg-discord-bot']:postToPlayerThread('license:xxxx', 'PlayerName', { embed })
```
