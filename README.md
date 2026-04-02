<div align="center">

# 🤖 DG Discord Bot

### Discord Integration Layer for DG Scripts

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![License](https://img.shields.io/badge/license-Commercial-red.svg)
![Dependency](https://img.shields.io/badge/dependency-oxmysql-green.svg)

**Webhook + Forum Thread logging for moderation, detections, and admin events**

[Overview](#-overview) • [Configuration](#%EF%B8%8F-configuration) • [Exports](#-exports) • [Installation](#-installation) • [Usage](#-usage)

---

</div>

## 📋 Overview

**DG Discord Bot** provides reusable Discord logging APIs for DG resources. It supports classic webhook embeds and Discord forum thread posting with per-player thread persistence.

| Property | Value |
|----------|-------|
| **Resource Name** | `dg-discord-bot` |
| **Version** | `1.0.0` |
| **Dependency** | `oxmysql` |
| **Storage Table** | `dg_discord_threads` |

---

## ✨ Features

- Webhook embed/message logging
- Discord Bot REST API forum thread posting
- Per-player thread mapping with DB persistence
- Automatic thread re-creation when deleted remotely
- Reusable embed builders for common moderation/security actions

---

## ⚙️ Configuration

Configure in `config.lua`:

- `Config.discordWebhookUrl`
- `Config.discordBotToken`
- `Config.discordForumChannelId`
- `Config.enableWebhook`
- `Config.enableBotAPI`
- `Config.enablePlayerThreads`

If placeholders remain, related integrations are skipped safely.

---

## 📤 Exports

This list matches current implementation.

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

---

## 💾 Database

Auto-created table:

```sql
CREATE TABLE IF NOT EXISTS dg_discord_threads (
    license VARCHAR(64) PRIMARY KEY,
    thread_id VARCHAR(32) NOT NULL,
    player_name VARCHAR(128),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)
```

---

## 📦 Installation

```cfg
ensure oxmysql
ensure dg-discord-bot
```

---

## 🧩 Usage

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

---

## 📝 Behavior Notes

- Thread mappings are cached in memory and persisted in MySQL
- If Discord returns `404` for a thread, mapping is reset and recreated on next post
- Presence/status management is intentionally outside this resource scope

---

## 📚 Related Resources

| Resource | Description |
|----------|-------------|
| [`dgscripts-admin-menu`](https://github.com/DreadedGScripts/dgscripts-admin-menu) | Admin panel and anti-cheat system |
| [`dg-bridge`](https://github.com/DreadedGScripts/dg-bridge) | Framework abstraction layer |
| [`dg-notifications`](https://github.com/DreadedGScripts/dg-notifications) | Realtime popup notifications |
