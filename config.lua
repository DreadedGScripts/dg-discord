Config = {}

-- ========================================
-- 💬 DISCORD INTEGRATION
-- ========================================
-- Get webhook: Server Settings > Integrations > Webhooks > New Webhook
Config.discordWebhookUrl = "PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE"

-- Get bot token: https://discord.com/developers/applications
Config.discordBotToken = "PASTE_YOUR_DISCORD_BOT_TOKEN_HERE"

-- Get channel ID: Right-click channel > Copy ID (requires Developer Mode enabled)
Config.discordForumChannelId = "PASTE_YOUR_FORUM_CHANNEL_ID_HERE"

-- Enable/disable features
Config.enableWebhook = true
Config.enableBotAPI = true
Config.enablePlayerThreads = true

return Config
