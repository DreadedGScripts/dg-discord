-- DG-Discord-Bot Server
-- Discord webhook and bot API integration

local DISCORD_WEBHOOK = Config.discordWebhookUrl or ""
local DISCORD_BOT_TOKEN = Config.discordBotToken or ""
local DISCORD_FORUM_CHANNEL_ID = Config.discordForumChannelId or ""
local ENABLE_CATEGORY_FORUMS = Config.enableCategoryForums ~= false
local LEGACY_WEBHOOK_FALLBACK = Config.legacyWebhookFallback ~= false
local FORUM_CATEGORIES = Config.forumCategories or {}

local playerThreads = {} -- In-memory cache: license -> Discord thread ID
local categoryThreads = {} -- In-memory cache: "category:threadKey" -> Discord thread ID

local function isPlaceholder(value, placeholder)
    return type(value) ~= 'string' or value == '' or value == placeholder
end

local function normalizeCategory(category)
    return tostring(category or ''):lower():gsub('[^%w_]', '_')
end

local function getCategoryForumChannelId(category)
    local normalized = normalizeCategory(category)
    local configured = FORUM_CATEGORIES[normalized]
    if configured and configured ~= '' and not tostring(configured):find('PASTE_') then
        return tostring(configured)
    end

    -- Keep compatibility with the old single-forum setup.
    if normalized == 'scores_detections' then
        return DISCORD_FORUM_CHANNEL_ID
    end

    return nil
end

local function safeSub(str, maxLen)
    local value = tostring(str or '')
    if #value <= maxLen then return value end
    return value:sub(1, math.max(1, maxLen - 1))
end

local function getCategoryThreadKey(category, payload)
    local normalized = normalizeCategory(category)
    payload = type(payload) == 'table' and payload or {}

    if normalized == 'join_leave' then
        return os.date('%Y-%m-%d')
    elseif normalized == 'scores_detections' then
        return tostring(payload.playerLicense or payload.license or payload.playerName or 'unknown')
    elseif normalized == 'reports' then
        return tostring(payload.reportId or ('reporter_' .. tostring(payload.reporterId or 'unknown')))
    elseif normalized == 'moderation' then
        return tostring(payload.targetLicense or payload.targetId or payload.targetName or 'unknown')
    elseif normalized == 'admin_audit' then
        return tostring(payload.adminLicense or payload.adminId or payload.adminName or 'unknown') .. ':' .. os.date('%Y-%m-%d')
    end

    return tostring(payload.threadKey or payload.playerLicense or payload.license or os.date('%Y-%m-%d'))
end

local function buildCategoryThreadName(category, payload)
    local normalized = normalizeCategory(category)
    payload = type(payload) == 'table' and payload or {}

    if normalized == 'join_leave' then
        return safeSub('🟢 Join/Leave - ' .. os.date('%Y-%m-%d'), 100)
    elseif normalized == 'scores_detections' then
        local playerName = payload.playerName or 'Unknown Player'
        return safeSub('📈 Scores - ' .. tostring(playerName), 100)
    elseif normalized == 'reports' then
        local reportId = payload.reportId and ('#' .. tostring(payload.reportId)) or '#new'
        return safeSub('📣 Reports ' .. reportId, 100)
    elseif normalized == 'moderation' then
        local targetName = payload.targetName or 'Unknown Player'
        return safeSub('🔨 Moderation - ' .. tostring(targetName), 100)
    elseif normalized == 'admin_audit' then
        local adminName = payload.adminName or 'Unknown Admin'
        return safeSub('🛡️ Audit - ' .. tostring(adminName) .. ' - ' .. os.date('%Y-%m-%d'), 100)
    end

    return safeSub('📌 ' .. tostring(category or 'general') .. ' - ' .. os.date('%Y-%m-%d'), 100)
end

local function createForumThread(forumChannelId, threadName, starterContent, callback)
    local body = json.encode({
        name = safeSub(threadName, 100),
        message = {
            content = tostring(starterContent or 'DG forum log thread initialized.')
        },
        auto_archive_duration = 10080
    })

    PerformHttpRequest(
        'https://discord.com/api/v10/channels/' .. tostring(forumChannelId) .. '/threads',
        function(statusCode, response)
            if statusCode == 200 or statusCode == 201 then
                local data = json.decode(response or '{}')
                if data and data.id then
                    if callback then callback(data.id) end
                    return
                end
            end

            print('^1[DG-Discord] Thread creation failed for forum ' .. tostring(forumChannelId) .. ' (HTTP ' .. tostring(statusCode) .. ')^0')
            if callback then callback(nil) end
        end,
        'POST', body,
        {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bot ' .. DISCORD_BOT_TOKEN,
        }
    )
end

local function getOrCreateCategoryThread(category, payload, callback)
    if not Config.enableBotAPI or not ENABLE_CATEGORY_FORUMS then
        if callback then callback(nil) end
        return
    end

    if isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE') then
        if callback then callback(nil) end
        return
    end

    local normalized = normalizeCategory(category)
    local forumChannelId = getCategoryForumChannelId(normalized)
    if not forumChannelId then
        if callback then callback(nil) end
        return
    end

    local threadKey = getCategoryThreadKey(normalized, payload)
    local cacheKey = normalized .. ':' .. threadKey
    if categoryThreads[cacheKey] then
        if callback then callback(categoryThreads[cacheKey], cacheKey) end
        return
    end

    MySQL.Async.fetchScalar(
        'SELECT thread_id FROM dg_discord_category_threads WHERE category_key = ? AND thread_key = ?',
        { normalized, threadKey },
        function(existingId)
            if existingId then
                categoryThreads[cacheKey] = tostring(existingId)
                if callback then callback(categoryThreads[cacheKey], cacheKey) end
                return
            end

            createForumThread(
                forumChannelId,
                buildCategoryThreadName(normalized, payload),
                '🧵 Category log thread for **' .. normalized .. '**.',
                function(createdThreadId)
                    if createdThreadId then
                        categoryThreads[cacheKey] = tostring(createdThreadId)
                        MySQL.Async.execute(
                            'INSERT IGNORE INTO dg_discord_category_threads (category_key, thread_key, thread_id, thread_name) VALUES (?, ?, ?, ?)',
                            { normalized, threadKey, createdThreadId, buildCategoryThreadName(normalized, payload) }
                        )
                    end

                    if callback then callback(createdThreadId, cacheKey) end
                end
            )
        end
    )
end

local function fallbackToWebhook(category, payload)
    if not LEGACY_WEBHOOK_FALLBACK then return end

    payload = type(payload) == 'table' and payload or {}

    if payload.title and payload.description then
        sendDiscordMessage(payload.title, payload.description, payload.color or 3447003, payload.fields or {})
        return
    end

    if payload.embeds and payload.embeds[1] then
        local first = payload.embeds[1]
        sendDiscordMessage(
            first.title or ('Forum Log - ' .. tostring(category or 'general')),
            first.description or 'Fallback webhook log.',
            first.color or 3447003,
            first.fields or {}
        )
    elseif payload.message then
        logToDiscord('Forum Log - ' .. tostring(category or 'general'), tostring(payload.message), payload.color or 3447003)
    end
end

-- ==========================================
-- BASIC WEBHOOK LOGGING
-- ==========================================

-- Export: Simple Discord webhook logging
function logToDiscord(title, message, color)
    if not Config.enableWebhook then return end
    local webhook = DISCORD_WEBHOOK
    if webhook == '' or webhook == 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE' then return end
    
    PerformHttpRequest(webhook, function() end, 'POST', json.encode({
        username = 'DG AdminPanel',
        embeds = {{
            title = title,
            description = message,
            color = color or 16711680,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') }
        }}
    }), { ['Content-Type'] = 'application/json' })
end

-- Export: Send Discord message with custom fields
function sendDiscordMessage(title, description, color, extraFields)
    if not Config.enableWebhook then return end
    if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" or DISCORD_WEBHOOK == 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE' then return end
    
    local fields = extraFields or {}
    table.insert(fields, { name = 'Timestamp', value = os.date('%Y-%m-%d %H:%M:%S'), inline = true })
    
    local embed = {
        {
            title = title,
            description = description,
            color = color or 3447003,
            fields = fields,
            footer = { text = 'dg-adminpanel' }
        }
    }
    
    PerformHttpRequest(DISCORD_WEBHOOK, function(statusCode, response, headers)
        -- Silently handle response
    end, 'POST', json.encode({ embeds = embed }), { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    Wait(1500)

    local warnings = {}

    if Config.enableWebhook and isPlaceholder(DISCORD_WEBHOOK, 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE') then
        table.insert(warnings, 'Webhook logging enabled but Config.discordWebhookUrl is not configured.')
    end

    if Config.enableBotAPI and isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE') then
        table.insert(warnings, 'Bot API enabled but Config.discordBotToken is not configured.')
    end

    if Config.enablePlayerThreads and isPlaceholder(DISCORD_FORUM_CHANNEL_ID, 'PASTE_YOUR_FORUM_CHANNEL_ID_HERE') then
        table.insert(warnings, 'Player threads enabled but Config.discordForumChannelId is not configured.')
    end

    for _, warning in ipairs(warnings) do
        print('^3[DG-Discord] WARNING: ' .. warning .. '^0')
    end

    if Config.enableWebhook and not isPlaceholder(DISCORD_WEBHOOK, 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE') then
        logToDiscord('DG Discord Bot Online', 'Monitoring users', 5763719)
    end
end)

-- ==========================================
-- DISCORD BOT API & FORUM THREADS
-- ==========================================

-- Export: Get or create a player's dedicated forum thread
function getOrCreatePlayerThread(license, playerName, callback)
    if not Config.enableBotAPI or not Config.enablePlayerThreads then
        if callback then callback(nil) end
        return
    end
    
    if not DISCORD_BOT_TOKEN or DISCORD_BOT_TOKEN == '' or DISCORD_BOT_TOKEN == 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE' then
        if callback then callback(nil) end
        return
    end
    
    if not DISCORD_FORUM_CHANNEL_ID or DISCORD_FORUM_CHANNEL_ID == '' or DISCORD_FORUM_CHANNEL_ID == 'PASTE_YOUR_FORUM_CHANNEL_ID_HERE' then
        if callback then callback(nil) end
        return
    end
    
    -- Check cache first
    if playerThreads[license] then
        if callback then callback(playerThreads[license]) end
        return
    end
    
    -- Check database for existing thread
    MySQL.Async.fetchScalar(
        'SELECT thread_id FROM dg_discord_threads WHERE license = ?',
        {license},
        function(existingId)
            if existingId then
                playerThreads[license] = tostring(existingId)
                if callback then callback(playerThreads[license]) end
            else
                -- Create new forum thread via Discord Bot API
                local threadName = ('🚨 ' .. playerName .. ' - Cheat Detection'):sub(1, 100)
                local body = json.encode({
                    name = threadName,
                    message = {
                        content = '🔴 **Anti-Cheat Detection Thread**\nThis thread tracks all suspicious activity for this player.'
                    },
                    auto_archive_duration = 10080 -- 1 week
                })
                
                PerformHttpRequest(
                    'https://discord.com/api/v10/channels/' .. DISCORD_FORUM_CHANNEL_ID .. '/threads',
                    function(statusCode, response, headers)
                        if statusCode == 200 or statusCode == 201 then
                            local data = json.decode(response or '{}')
                            if data and data.id then
                                playerThreads[license] = data.id
                                MySQL.Async.execute(
                                    'INSERT IGNORE INTO dg_discord_threads (license, thread_id, player_name) VALUES (?, ?, ?)',
                                    {license, data.id, playerName}
                                )
                                if callback then callback(data.id) end
                            else
                                print('^1[DG-Discord] Thread creation returned no ID^0')
                                if callback then callback(nil) end
                            end
                        else
                            print('^1[DG-Discord] Thread creation FAILED (HTTP ' .. tostring(statusCode) .. ')^0')
                            print('^1[DG-Discord] Response: ' .. tostring(response) .. '^0')
                            if callback then callback(nil) end
                        end
                    end,
                    'POST', body,
                    {
                        ['Content-Type'] = 'application/json',
                        ['Authorization'] = 'Bot ' .. DISCORD_BOT_TOKEN,
                    }
                )
            end
        end
    )
end

-- Export: Post message to player's forum thread
function postToPlayerThread(license, playerName, embeds)
    if not Config.enableBotAPI or not Config.enablePlayerThreads then return end
    
    getOrCreatePlayerThread(license, playerName, function(threadId)
        if not threadId then 
            print('^1[DG-Discord] No thread ID, cannot post^0')
            return 
        end
        
        local payload = json.encode({ embeds = embeds })
        local url = 'https://discord.com/api/v10/channels/' .. threadId .. '/messages'
        
        PerformHttpRequest(
            url,
            function(statusCode, response, headers)
                -- Handle 404: thread was deleted
                if statusCode == 404 then
                    print('^3[DG-Discord] Thread deleted (404) - Recreating for ' .. playerName .. '^0')
                    playerThreads[license] = nil
                    MySQL.Async.execute('DELETE FROM dg_discord_threads WHERE license = ?', {license}, function()
                        postToPlayerThread(license, playerName, embeds)
                    end)
                elseif statusCode ~= 200 and statusCode ~= 201 then
                    print('^1[DG-Discord] Failed to post (HTTP ' .. tostring(statusCode) .. ')^0')
                end
            end,
            'POST', payload,
            {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bot ' .. DISCORD_BOT_TOKEN,
            }
        )
    end)
end

-- Export: Post a category log into category-specific forum threads with webhook fallback.
function postToCategoryForum(category, payload)
    payload = type(payload) == 'table' and payload or {}
    local embeds = payload.embeds
    if not embeds then
        embeds = {
            {
                title = payload.title or ('Log - ' .. tostring(category or 'general')),
                description = payload.description or payload.message or 'No message provided.',
                color = payload.color or 3447003,
                fields = payload.fields or {},
                footer = { text = payload.footerText or 'DG Logging' },
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
            }
        }
    end

    getOrCreateCategoryThread(category, payload, function(threadId, cacheKey)
        if not threadId then
            fallbackToWebhook(category, payload)
            return
        end

        local requestBody = json.encode({ embeds = embeds })
        local postUrl = 'https://discord.com/api/v10/channels/' .. tostring(threadId) .. '/messages'

        PerformHttpRequest(postUrl, function(statusCode)
            if statusCode == 404 then
                if cacheKey then categoryThreads[cacheKey] = nil end

                local normalized = normalizeCategory(category)
                local threadKey = getCategoryThreadKey(normalized, payload)
                MySQL.Async.execute(
                    'DELETE FROM dg_discord_category_threads WHERE category_key = ? AND thread_key = ?',
                    { normalized, threadKey },
                    function()
                        postToCategoryForum(category, payload)
                    end
                )
                return
            end

            if statusCode ~= 200 and statusCode ~= 201 then
                print('^1[DG-Discord] Category post failed for ' .. tostring(category) .. ' (HTTP ' .. tostring(statusCode) .. ')^0')
                fallbackToWebhook(category, payload)
            end
        end,
        'POST', requestBody,
        {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bot ' .. DISCORD_BOT_TOKEN,
        })
    end)
end

-- ==========================================
-- EMBED BUILDERS
-- ==========================================

-- Detection type names with emojis
local detectionNames = {
    speedhack = "🏃 Speedhack",
    teleport = "🌀 Teleport",
    godmode = "⚔️ Godmode",
    infinite_armor = "🛡️ Infinite Armor",
    noclip_fly = "🚁 Noclip/Flying",
    super_jump = "⬆️ Super Jump",
    rapid_fire = "🔫 Rapid Fire",
    blacklisted_weapon = "🚫 Blacklisted Weapon",
    blacklisted_vehicle = "🚗 Blacklisted Vehicle",
    crash_vehicle_detected = "💥 Crash Vehicle",
    money_injection = "💰 Money Injection",
}

local function getDetectionName(reason)
    return detectionNames[reason] or ("🔔 " .. reason:gsub("_", " "):upper())
end

local function getWeightEmoji(weight)
    if weight == 'critical' then return "🔴 CRITICAL" end
    if weight == 'medium' then return "🟡 MEDIUM" end
    return "🟢 LOW"
end

-- Export: Build detection embed
function buildDetectionEmbed(playerName, reason, weight, score, scoreIncrease, details, identifiers)
    local detailsStr = ""
    if type(details) == 'table' then
        for k, v in pairs(details) do
            if k ~= 'weight' and k ~= 'pos' and k ~= 'test' then
                local keyName = k:gsub('_', ' '):gsub("(%a)([%w_']*)", function(first, rest)
                    return first:upper() .. rest:lower()
                end)
                detailsStr = detailsStr .. "**" .. keyName .. ":** " .. tostring(v) .. "\n"
            end
        end
    end
    
    local fields = {
        { name = '⚠️ Detection', value = getDetectionName(reason), inline = true },
        { name = '📊 Severity', value = getWeightEmoji(weight), inline = true },
        { name = '🎯 Score', value = '**' .. score .. '**/8 *(+' .. scoreIncrease .. ')*', inline = true },
    }
    
    if detailsStr ~= "" then
        table.insert(fields, { name = '📋 Details', value = detailsStr:sub(1, 1000), inline = false })
    end
    
    return {
        color = (weight == 'critical' and 15158332) or (weight == 'medium' and 15105570) or 3066993,
        description = '🚨 **' .. playerName .. '** triggered a cheat detection',
        fields = fields,
        footer = { text = 'DG Anti-Cheat' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build player info embed
function buildPlayerInfoEmbed(playerName, license, identifiers, serverId, ping)
    local fields = {
        { name = '🎮 Player Name', value = '**' .. playerName .. '**', inline = true },
        { name = '🔢 Server ID', value = '`' .. tostring(serverId or 'N/A') .. '`', inline = true },
        { name = '📶 Ping', value = tostring(ping or 'N/A') .. ' ms', inline = true },
    }
    
    table.insert(fields, { name = '🔑 FiveM License', value = '```' .. license .. '```', inline = false })
    
    if identifiers.steamid and identifiers.steamid ~= 'N/A' then
        table.insert(fields, { name = '🎯 Steam ID', value = '`' .. identifiers.steamid .. '`', inline = true })
    else
        table.insert(fields, { name = '🎯 Steam ID', value = 'Not Linked', inline = true })
    end
    
    if identifiers.discord and identifiers.discord ~= 'N/A' then
        local discordId = identifiers.discord:gsub('discord:', '')
        table.insert(fields, { name = '💬 Discord', value = '<@' .. discordId .. '>', inline = true })
    else
        table.insert(fields, { name = '💬 Discord', value = 'Not Linked', inline = true })
    end
    
    table.insert(fields, { name = '📅 Thread Created', value = os.date('%B %d, %Y at %I:%M %p'), inline = false })
    
    return {
        color = 0x5865F2,
        title = '👤 Player Information',
        description = '⚠️ **Anti-Cheat Monitoring Active** ⚠️\nAll suspicious activity will be logged below.',
        fields = fields,
        footer = { text = 'DG Anti-Cheat Detection System' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Ensure Discord threads table exists
CreateThread(function()
    MySQL.ready(function()
        MySQL.Async.execute([[CREATE TABLE IF NOT EXISTS dg_discord_threads (
            license VARCHAR(64) PRIMARY KEY,
            thread_id VARCHAR(32) NOT NULL,
            player_name VARCHAR(128),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )]], {}, function() end)

        MySQL.Async.execute([[CREATE TABLE IF NOT EXISTS dg_discord_category_threads (
            id INT AUTO_INCREMENT PRIMARY KEY,
            category_key VARCHAR(64) NOT NULL,
            thread_key VARCHAR(191) NOT NULL,
            thread_id VARCHAR(32) NOT NULL,
            thread_name VARCHAR(128),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uniq_category_thread (category_key, thread_key)
        )]], {}, function() end)
    end)
end)

-- ==========================================
-- ADDITIONAL EMBED BUILDERS
-- ==========================================

-- Export: Build ban notification embed
function buildBanEmbed(playerName, adminName, reason, duration, license, identifiers)
    local banType = duration and duration > 0 and "Temporary Ban" or "Permanent Ban"
    local durationText = duration and duration > 0 and ("**Duration:** " .. tostring(duration) .. " hours") or "**Duration:** Permanent"
    
    local fields = {
        { name = '⛔ Ban Type', value = banType, inline = true },
        { name = '⏰ Duration', value = durationText, inline = true },
        { name = '👮 Admin', value = adminName, inline = true },
        { name = '📝 Reason', value = reason or 'No reason provided', inline = false },
        { name = '🔑 License', value = '```' .. license .. '```', inline = false },
    }
    
    if identifiers.steamid and identifiers.steamid ~= 'N/A' then
        table.insert(fields, { name = '🎯 Steam ID', value = '`' .. identifiers.steamid .. '`', inline = true })
    end
    
    if identifiers.discord and identifiers.discord ~= 'N/A' then
        local discordId = identifiers.discord:gsub('discord:', '')
        table.insert(fields, { name = '💬 Discord', value = '<@' .. discordId .. '>', inline = true })
    end
    
    return {
        color = 0xFF0000, -- Red
        title = '🔨 Player Banned',
        description = '**' .. playerName .. '** has been banned from the server',
        fields = fields,
        footer = { text = 'DG AdminPanel - Ban System' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build kick notification embed
function buildKickEmbed(playerName, adminName, reason, serverId)
    return {
        color = 0xFFA500, -- Orange
        title = '👢 Player Kicked',
        description = '**' .. playerName .. '** has been kicked from the server',
        fields = {
            { name = '👮 Admin', value = adminName, inline = true },
            { name = '🔢 Server ID', value = tostring(serverId), inline = true },
            { name = '📝 Reason', value = reason or 'No reason provided', inline = false },
        },
        footer = { text = 'DG AdminPanel - Kick System' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build player connection embed
function buildConnectionEmbed(playerName, license, identifiers, joining)
    local title = joining and '✅ Player Joined' or '❌ Player Left'
    local description = '**' .. playerName .. '** has ' .. (joining and 'joined' or 'left') .. ' the server'
    local color = joining and 0x00FF00 or 0xFF0000 -- Green or Red
    
    local fields = {
        { name = '🔑 License', value = '`' .. license:sub(1, 20) .. '...`', inline = true },
    }
    
    if identifiers.steamid and identifiers.steamid ~= 'N/A' then
        table.insert(fields, { name = '🎯 Steam', value = '`' .. identifiers.steamid:sub(1, 15) .. '...`', inline = true })
    end
    
    if identifiers.discord and identifiers.discord ~= 'N/A' then
        local discordId = identifiers.discord:gsub('discord:', '')
        table.insert(fields, { name = '💬 Discord', value = '<@' .. discordId .. '>', inline = true })
    end
    
    return {
        color = color,
        title = title,
        description = description,
        fields = fields,
        footer = { text = 'DG Connection Logger' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build admin action embed (generic admin log)
function buildAdminActionEmbed(adminName, actionType, targetPlayer, details)
    local colorMap = {
        warn = 0xFFFF00,     -- Yellow
        teleport = 0x00FFFF, -- Cyan
        freeze = 0x0099FF,   -- Blue
        revive = 0x00FF00,   -- Green
        heal = 0x00FF99,     -- Mint
        give_item = 0x9900FF, -- Purple
        give_money = 0xFFD700, -- Gold
        remove_item = 0xFF6600, -- Orange-Red
        god_mode = 0xFF00FF,  -- Magenta
        noclip = 0xCCCCCC,   -- Gray
    }
    
    local color = colorMap[actionType] or 0x5865F2
    
    return {
        color = color,
        title = '🛡️ Admin Action',
        description = '**' .. adminName .. '** performed: `' .. actionType:upper() .. '`',
        fields = {
            { name = '🎯 Target', value = targetPlayer or 'N/A', inline = true },
            { name = '📋 Details', value = details or 'No details provided', inline = false },
        },
        footer = { text = 'DG AdminPanel - Action Log' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build warning/moderation embed
function buildWarningEmbed(playerName, adminName, warnCount, reason)
    local color = warnCount >= 3 and 0xFF0000 or (warnCount >= 2 and 0xFFA500 or 0xFFFF00)
    local severity = warnCount >= 3 and '🔴 **SEVERE**' or (warnCount >= 2 and '🟠 **HIGH**' or '🟡 **LOW**')
    
    return {
        color = color,
        title = '⚠️ Player Warning',
        description = '**' .. playerName .. '** received a warning',
        fields = {
            { name = '👮 Admin', value = adminName, inline = true },
            { name = '🔔 Total Warnings', value = tostring(warnCount), inline = true },
            { name = '📊 Severity', value = severity, inline = true },
            { name = '📝 Reason', value = reason or 'No reason provided', inline = false },
        },
        footer = { text = 'DG AdminPanel - Warning System' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build AI suggestion embed (for Copilot/AI features)
function buildAISuggestionEmbed(suggestion, confidence, context)
    local color = confidence >= 0.8 and 0x00FF00 or (confidence >= 0.5 and 0xFFFF00 or 0xFF0000)
    local confidencePercent = math.floor(confidence * 100)
    
    return {
        color = color,
        title = '🤖 AI Detection Suggestion',
        description = suggestion,
        fields = {
            { name = '📊 Confidence', value = confidencePercent .. '%', inline = true },
            { name = '📋 Context', value = context or 'No context provided', inline = false },
        },
        footer = { text = 'DG Anti-Cheat AI System' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build economy transaction embed
function buildTransactionEmbed(playerName, transactionType, amount, item, adminName)
    local emoji = transactionType == 'give' and '➕' or '➖'
    local color = transactionType == 'give' and 0x00FF00 or 0xFF0000
    
    local description = item and 
        ('**' .. playerName .. '** ' .. (transactionType == 'give' and 'received' or 'had removed') .. ' **' .. amount .. 'x ' .. item .. '**') or
        ('**' .. playerName .. '** ' .. (transactionType == 'give' and 'received' or 'had removed') .. ' **$' .. amount .. '**')
    
    return {
        color = color,
        title = emoji .. ' ' .. (transactionType == 'give' and 'Item/Money Given' or 'Item/Money Removed'),
        description = description,
        fields = {
            { name = '👮 Admin', value = adminName or 'System', inline = true },
            { name = '💰 Amount', value = tostring(amount), inline = true },
            { name = '📦 Item', value = item or 'Money', inline = true },
        },
        footer = { text = 'DG AdminPanel - Economy Log' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build vehicle spawn embed
function buildVehicleSpawnEmbed(playerName, adminName, vehicleModel, plate)
    return {
        color = 0x0099FF,
        title = '🚗 Vehicle Spawned',
        description = '**' .. adminName .. '** spawned a vehicle for **' .. playerName .. '**',
        fields = {
            { name = '🚙 Vehicle Model', value = vehicleModel, inline = true },
            { name = '🔖 Plate', value = plate or 'N/A', inline = true },
        },
        footer = { text = 'DG AdminPanel - Vehicle Log' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

-- Export: Build server event embed (custom events)
function buildServerEventEmbed(eventName, description, details, color)
    local fields = {}
    
    if type(details) == 'table' then
        for key, value in pairs(details) do
            table.insert(fields, { 
                name = tostring(key), 
                value = tostring(value), 
                inline = true 
            })
        end
    end
    
    return {
        color = color or 0x5865F2,
        title = '📡 Server Event',
        description = '**Event:** `' .. eventName .. '`\n' .. (description or ''),
        fields = fields,
        footer = { text = 'DG Server Event Logger' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

print('^2[DG-Discord-Bot] Server initialized^0')

