-- DG-Discord-Bot Server
-- Discord webhook and bot API integration

local DISCORD_WEBHOOK = Config.discordWebhookUrl or ""
local DISCORD_BOT_TOKEN = Config.discordBotToken or ""
local DISCORD_FORUM_CHANNEL_ID = Config.discordForumChannelId or ""
local WEBHOOK_THREAD_NAME = tostring(Config.webhookThreadName or '')
local WEBHOOK_THREAD_NAMES = type(Config.webhookThreadNames) == 'table' and Config.webhookThreadNames or {}
local CATEGORY_THREAD_STRATEGY = type(Config.categoryThreadStrategy) == 'table' and Config.categoryThreadStrategy or {}
local ENABLE_CATEGORY_FORUMS = Config.enableCategoryForums ~= false
local LEGACY_WEBHOOK_FALLBACK = Config.legacyWebhookFallback ~= false
local FORUM_CATEGORIES = Config.forumCategories or {}
local CATEGORY_LOG_TRANSPORT = tostring(Config.categoryLogTransport or 'webhook'):lower()
local THREAD_CLEANUP_ON_STARTUP = type(Config.threadCleanupOnStartup) == 'table' and Config.threadCleanupOnStartup or {}

local playerThreads = {} -- In-memory cache: license -> Discord thread ID
local categoryThreads = {} -- In-memory cache: "category:threadKey" -> Discord thread ID

local function logDiscordHttpFailure(scope, statusCode, response)
    local snippet = tostring(response or '')
    if #snippet > 240 then
        snippet = snippet:sub(1, 240) .. '...'
    end
    print('^1[DG-Discord] ' .. tostring(scope) .. ' failed (HTTP ' .. tostring(statusCode) .. ') | ' .. snippet .. '^0')
end

local function isPlaceholder(value, placeholder)
    return type(value) ~= 'string' or value == '' or value == placeholder
end

local function deleteDiscordThread(threadId, callback)
    local id = tostring(threadId or '')
    if id == '' then
        if callback then callback(true) end
        return
    end

    PerformHttpRequest(
        'https://discord.com/api/v10/channels/' .. id,
        function(statusCode, response)
            if statusCode == 200 or statusCode == 202 or statusCode == 204 or statusCode == 404 then
                if callback then callback(true) end
                return
            end

            logDiscordHttpFailure('Thread delete (' .. id .. ')', statusCode, response)
            if callback then callback(false) end
        end,
        'DELETE',
        '',
        {
            ['Authorization'] = 'Bot ' .. DISCORD_BOT_TOKEN,
        }
    )
end

local function runStartupThreadCleanup(callback)
    if THREAD_CLEANUP_ON_STARTUP.enabled ~= true then
        if callback then callback() end
        return
    end

    if isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE') then
        print('^3[DG-Discord] Startup thread cleanup skipped: bot token is not configured.^0')
        if callback then callback() end
        return
    end

    local collectedIds = {}
    local seen = {}

    local function addThreadId(threadId)
        local id = tostring(threadId or '')
        if id == '' or seen[id] then return end
        seen[id] = true
        table.insert(collectedIds, id)
    end

    local function clearMappingsAndFinish()
        playerThreads = {}
        categoryThreads = {}

        local deleteStatements = {}
        if THREAD_CLEANUP_ON_STARTUP.deletePlayerThreads ~= false then
            table.insert(deleteStatements, 'DELETE FROM dg_discord_threads')
        end
        if THREAD_CLEANUP_ON_STARTUP.deleteCategoryThreads ~= false then
            table.insert(deleteStatements, 'DELETE FROM dg_discord_category_threads')
        end

        local idx = 1
        local function runDelete()
            local stmt = deleteStatements[idx]
            if not stmt then
                if callback then callback() end
                return
            end

            MySQL.Async.execute(stmt, {}, function()
                idx = idx + 1
                runDelete()
            end)
        end

        runDelete()
    end

    local function deleteCollected(index)
        if index > #collectedIds then
            print(('^2[DG-Discord] Startup thread cleanup complete. Removed %d Discord thread reference(s).^0'):format(#collectedIds))
            clearMappingsAndFinish()
            return
        end

        deleteDiscordThread(collectedIds[index], function()
            deleteCollected(index + 1)
        end)
    end

    local function collectCategoryThreads()
        if THREAD_CLEANUP_ON_STARTUP.deleteCategoryThreads == false then
            deleteCollected(1)
            return
        end

        MySQL.Async.fetchAll('SELECT thread_id FROM dg_discord_category_threads', {}, function(rows)
            for _, row in ipairs(rows or {}) do
                addThreadId(row.thread_id)
            end
            deleteCollected(1)
        end)
    end

    if THREAD_CLEANUP_ON_STARTUP.deletePlayerThreads == false then
        collectCategoryThreads()
        return
    end

    MySQL.Async.fetchAll('SELECT thread_id FROM dg_discord_threads', {}, function(rows)
        for _, row in ipairs(rows or {}) do
            addThreadId(row.thread_id)
        end
        collectCategoryThreads()
    end)
end

local function coerceString(value, fallback)
    if type(value) == 'table' then
        return tostring(value.playerName or value.targetName or value.name or value.license or value.playerLicense or fallback or '')
    end
    if value == nil then
        return tostring(fallback or '')
    end
    return tostring(value)
end

local function coerceNumber(value, fallback)
    if type(value) == 'table' then
        return tonumber(value.score or value.points or value.value or fallback) or tonumber(fallback) or 0
    end
    return tonumber(value) or tonumber(fallback) or 0
end

local function coerceTable(value)
    return type(value) == 'table' and value or {}
end

local function normalizeCategory(category)
    local normalized = tostring(category or ''):lower():gsub('[^%w_]', '_')

    -- Canonical category aliases to prevent accidental routing drift.
    if normalized == 'detection' or normalized == 'detections' or normalized == 'score_detection' then
        return 'scores_detections'
    end

    if normalized == 'admin_action' or normalized == 'actions' then
        return 'admin_actions'
    end

    if normalized == 'session' or normalized == 'player_activity' then
        return 'join_leave'
    end

    return normalized
end

local function getDefaultCategoryPostTitle(category)
    local normalized = normalizeCategory(category)
    if normalized == 'general' or normalized == 'join_leave' then
        return 'Session | Player Activity'
    elseif normalized == 'scores_detections' then
        return 'Detection Alerts | Score Update'
    elseif normalized == 'reports' then
        return 'Reports | Update'
    elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
        return 'Moderation | Action'
    end

    return 'DG Log | ' .. tostring(category or 'general')
end

local function getCategoryLabel(category)
    local normalized = normalizeCategory(category)
    if normalized == 'general' or normalized == 'join_leave' then
        return 'Player Join/Leave'
    elseif normalized == 'scores_detections' then
        return 'Detection Alerts'
    elseif normalized == 'reports' then
        return 'Reports'
    elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
        return 'Admin Actions'
    end

    return tostring(category or 'General')
end

local function resolveThreadStrategy(category, payload)
    payload = type(payload) == 'table' and payload or {}
    local normalized = normalizeCategory(category)

    if type(payload.threadStrategy) == 'string' and payload.threadStrategy ~= '' then
        return tostring(payload.threadStrategy):lower()
    end

    local configured = CATEGORY_THREAD_STRATEGY[normalized]
    if type(configured) == 'string' and configured ~= '' then
        return tostring(configured):lower()
    end

    return 'daily'
end

local function getCategoryForumChannelId(category)
    local normalized = normalizeCategory(category)
    local configured = FORUM_CATEGORIES[normalized]
    if configured and configured ~= '' and not tostring(configured):find('PASTE_') then
        return tostring(configured)
    end

    local generalConfigured = FORUM_CATEGORIES.general
    if generalConfigured and generalConfigured ~= '' and not tostring(generalConfigured):find('PASTE_') then
        return tostring(generalConfigured)
    end

    -- Keep compatibility with the old single-forum setup.
    if normalized == 'scores_detections' then
        return DISCORD_FORUM_CHANNEL_ID
    end

    if DISCORD_FORUM_CHANNEL_ID and DISCORD_FORUM_CHANNEL_ID ~= '' and DISCORD_FORUM_CHANNEL_ID ~= 'PASTE_YOUR_FORUM_CHANNEL_ID_HERE' then
        return DISCORD_FORUM_CHANNEL_ID
    end

    return nil
end

local function safeSub(str, maxLen)
    local value = tostring(str or '')
    if #value <= maxLen then return value end
    return value:sub(1, math.max(1, maxLen - 1))
end

local function buildWebhookThreadName(category, payload)
    payload = type(payload) == 'table' and payload or {}
    local normalized = normalizeCategory(category)
    local configured = WEBHOOK_THREAD_NAMES[normalized]

    if type(payload.webhookThreadName) == 'string' and payload.webhookThreadName ~= '' then
        return safeSub(payload.webhookThreadName, 90)
    end

    if type(configured) == 'string' and configured ~= '' then
        if normalized == 'general' or normalized == 'join_leave' then
            return safeSub(configured .. '-' .. os.date('%Y-%m-%d'), 90)
        end
        return safeSub(configured, 90)
    end

    if normalized == 'general' or normalized == 'join_leave' then
        return safeSub('player-join-leave-' .. os.date('%Y-%m-%d'), 90)
    elseif normalized == 'scores_detections' then
        return 'detection-alerts'
    elseif normalized == 'reports' then
        return 'admin-reports'
    elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
        return 'admin-actions'
    end

    if WEBHOOK_THREAD_NAME ~= '' then
        return safeSub(WEBHOOK_THREAD_NAME, 90)
    end

    return nil
end

local function sendWebhookPayload(payload, scopeLabel)
    if not Config.enableWebhook then return false end
    if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == '' or DISCORD_WEBHOOK == 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE' then
        return false
    end

    PerformHttpRequest(DISCORD_WEBHOOK, function(statusCode, response)
        if statusCode ~= 200 and statusCode ~= 201 and statusCode ~= 204 then
            logDiscordHttpFailure(scopeLabel or 'Webhook request', statusCode, response)
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })

    return true
end

local function canUseBotCategoryTransport(category)
    if not Config.enableBotAPI or not ENABLE_CATEGORY_FORUMS then
        return false
    end

    if isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE') then
        return false
    end

    return getCategoryForumChannelId(category) ~= nil
end

local function shouldUseWebhookTransportFirst(category)
    if CATEGORY_LOG_TRANSPORT == 'webhook' then
        return true
    end

    if CATEGORY_LOG_TRANSPORT == 'bot' then
        return false
    end

    -- auto mode: fallback to webhook first when bot transport is not available.
    return not canUseBotCategoryTransport(category)
end

local function getCategoryThreadKey(category, payload)
    local normalized = normalizeCategory(category)
    payload = type(payload) == 'table' and payload or {}
    local strategy = resolveThreadStrategy(normalized, payload)

    if strategy == 'single' then
        -- Versioned single-thread keys ensure legacy/stale DB mappings do not
        -- collapse detections/admin logs into join/leave threads.
        if normalized == 'scores_detections' then
            return 'scores_detections_v2'
        elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
            return 'admin_actions_v2'
        elseif normalized == 'general' or normalized == 'join_leave' then
            return 'join_leave_v1'
        end
        return normalized
    elseif strategy == 'daily' then
        return os.date('%Y-%m-%d')
    elseif strategy == 'per_player' then
        return tostring(payload.playerLicense or payload.license or payload.playerName or payload.targetLicense or payload.targetId or payload.targetName or 'unknown')
    elseif strategy == 'per_report' then
        return tostring(payload.reportId or ('reporter_' .. tostring(payload.reporterId or 'unknown')))
    elseif strategy == 'per_admin_day' then
        return tostring(payload.adminLicense or payload.adminId or payload.adminName or 'admin') .. ':' .. os.date('%Y-%m-%d')
    elseif strategy == 'custom' and payload.threadKey then
        return tostring(payload.threadKey)
    end

    if normalized == 'general' or normalized == 'join_leave' then
        return os.date('%Y-%m-%d')
    elseif normalized == 'scores_detections' then
        return tostring(payload.playerLicense or payload.license or payload.playerName or 'unknown')
    elseif normalized == 'reports' then
        return tostring(payload.reportId or ('reporter_' .. tostring(payload.reporterId or 'unknown')))
    elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
        return 'admin-actions'
    end

    return tostring(payload.threadKey or payload.playerLicense or payload.license or os.date('%Y-%m-%d'))
end

local function buildCategoryThreadName(category, payload)
    local normalized = normalizeCategory(category)
    payload = type(payload) == 'table' and payload or {}
    local strategy = resolveThreadStrategy(normalized, payload)
    local categoryLabel = getCategoryLabel(normalized)
    local configuredSlug = WEBHOOK_THREAD_NAMES[normalized]

    if strategy == 'single' then
        if type(configuredSlug) == 'string' and configuredSlug ~= '' then
            return safeSub(configuredSlug, 100)
        end
        return safeSub(string.lower(categoryLabel:gsub('[^%w]+', '-')), 100)
    elseif strategy == 'daily' then
        if type(configuredSlug) == 'string' and configuredSlug ~= '' then
            return safeSub(configuredSlug .. '-' .. os.date('%Y-%m-%d'), 100)
        end
        return safeSub(string.lower(categoryLabel:gsub('[^%w]+', '-')) .. '-' .. os.date('%Y-%m-%d'), 100)
    elseif strategy == 'per_player' then
        local playerName = payload.playerName or payload.targetName or 'Unknown Player'
        return safeSub('🧵 ' .. categoryLabel .. ' - ' .. tostring(playerName), 100)
    elseif strategy == 'per_report' then
        local reportId = payload.reportId and ('#' .. tostring(payload.reportId)) or '#new'
        return safeSub('🧵 ' .. categoryLabel .. ' ' .. reportId, 100)
    elseif strategy == 'per_admin_day' then
        local adminName = payload.adminName or 'Unknown Admin'
        return safeSub('🧵 ' .. categoryLabel .. ' - ' .. tostring(adminName) .. ' - ' .. os.date('%Y-%m-%d'), 100)
    elseif strategy == 'custom' and payload.threadName then
        return safeSub(tostring(payload.threadName), 100)
    end

    if normalized == 'general' or normalized == 'join_leave' then
        return safeSub('🟢 Join/Leave - ' .. os.date('%Y-%m-%d'), 100)
    elseif normalized == 'scores_detections' then
        return safeSub('🚨 Detection Alerts', 100)
    elseif normalized == 'reports' then
        local reportId = payload.reportId and ('#' .. tostring(payload.reportId)) or '#new'
        return safeSub('📣 Reports ' .. reportId, 100)
    elseif normalized == 'moderation' or normalized == 'admin_audit' or normalized == 'admin_actions' then
        return safeSub('🛡️ Admin Actions', 100)
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

            logDiscordHttpFailure('Thread creation (forum ' .. tostring(forumChannelId) .. ')', statusCode, response)
            print('^3[DG-Discord] Verify forum channel ID is the parent FORUM channel ID (not an existing thread ID) and bot has Create Public Threads + Send Messages in Threads.^0')
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
        print('^3[DG-Discord] Category thread skipped: bot API or category forums are disabled.^0')
        if callback then callback(nil) end
        return
    end

    if isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE') then
        print('^1[DG-Discord] Category thread skipped: Config.discordBotToken is not configured.^0')
        if callback then callback(nil) end
        return
    end

    local normalized = normalizeCategory(category)
    local forumChannelId = getCategoryForumChannelId(normalized)
    if not forumChannelId then
        print('^1[DG-Discord] Category thread skipped: no forum channel mapped for category ' .. tostring(normalized) .. '.^0')
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
                    if not createdThreadId
                        and DISCORD_FORUM_CHANNEL_ID
                        and DISCORD_FORUM_CHANNEL_ID ~= ''
                        and DISCORD_FORUM_CHANNEL_ID ~= 'PASTE_YOUR_FORUM_CHANNEL_ID_HERE'
                        and tostring(forumChannelId) ~= tostring(DISCORD_FORUM_CHANNEL_ID) then
                        print('^3[DG-Discord] Retrying category thread on default forum channel ' .. tostring(DISCORD_FORUM_CHANNEL_ID) .. ' for category ' .. tostring(normalized) .. '.^0')

                        createForumThread(
                            DISCORD_FORUM_CHANNEL_ID,
                            buildCategoryThreadName(normalized, payload),
                            '🧵 Category log thread for **' .. normalized .. '**.',
                            function(retryThreadId)
                                if retryThreadId then
                                    categoryThreads[cacheKey] = tostring(retryThreadId)
                                    MySQL.Async.execute(
                                        'INSERT IGNORE INTO dg_discord_category_threads (category_key, thread_key, thread_id, thread_name) VALUES (?, ?, ?, ?)',
                                        { normalized, threadKey, retryThreadId, buildCategoryThreadName(normalized, payload) }
                                    )
                                end

                                if callback then callback(retryThreadId, cacheKey) end
                            end
                        )
                        return
                    end

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
    local threadName = buildWebhookThreadName(category, payload)

    if payload.title and payload.description then
        local fields = payload.fields or {}
        table.insert(fields, { name = 'Timestamp', value = os.date('%Y-%m-%d %H:%M:%S'), inline = true })

        local webhookPayload = {
            embeds = {
                {
                    title = payload.title,
                    description = payload.description,
                    color = payload.color or 3447003,
                    fields = fields,
                    footer = { text = 'dg-adminpanel' }
                }
            }
        }

        if threadName then
            webhookPayload.thread_name = threadName
        end

        if not sendWebhookPayload(webhookPayload, 'Webhook fallback (title)') then
            sendDiscordMessage(payload.title, payload.description, payload.color or 3447003, payload.fields or {})
        end
        return
    end

    if payload.embeds and payload.embeds[1] then
        local webhookPayload = { embeds = payload.embeds }

        if threadName then
            webhookPayload.thread_name = threadName
        end

        if not sendWebhookPayload(webhookPayload, 'Webhook fallback (embeds)') then
            local first = payload.embeds[1]
            sendDiscordMessage(
                first.title or ('Forum Log - ' .. tostring(category or 'general')),
                first.description or 'Fallback webhook log.',
                first.color or 3447003,
                first.fields or {}
            )
        end
    elseif payload.message then
        local webhookPayload = {
            embeds = {
                {
                    title = 'Forum Log - ' .. tostring(category or 'general'),
                    description = tostring(payload.message),
                    color = payload.color or 3447003,
                    footer = { text = os.date('%Y-%m-%d %H:%M:%S') }
                }
            }
        }

        if threadName then
            webhookPayload.thread_name = threadName
        end

        if not sendWebhookPayload(webhookPayload, 'Webhook fallback (message)') then
            logToDiscord('Forum Log - ' .. tostring(category or 'general'), tostring(payload.message), payload.color or 3447003)
        end
    end
end

-- ==========================================
-- BASIC WEBHOOK LOGGING
-- ==========================================

local function canUseBotLogging()
    return Config.enableBotAPI
        and not isPlaceholder(DISCORD_BOT_TOKEN, 'PASTE_YOUR_DISCORD_BOT_TOKEN_HERE')
        and (DISCORD_FORUM_CHANNEL_ID and DISCORD_FORUM_CHANNEL_ID ~= '' and DISCORD_FORUM_CHANNEL_ID ~= 'PASTE_YOUR_FORUM_CHANNEL_ID_HERE')
end

-- Export: Simple Discord webhook logging
function logToDiscord(title, message, color)
    if not Config.enableWebhook then
        if canUseBotLogging() then
            postToCategoryForum('admin_audit', {
                title = tostring(title or 'DG Log'),
                description = tostring(message or 'No message provided.'),
                color = color or 3447003
            })
        end
        return
    end

    local webhook = DISCORD_WEBHOOK
    if webhook == '' or webhook == 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE' then return end
    
    local payload = {
        username = 'DG AdminPanel',
        embeds = {{
            title = title,
            description = message,
            color = color or 16711680,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') }
        }}
    }

    if WEBHOOK_THREAD_NAME ~= '' then
        payload.thread_name = WEBHOOK_THREAD_NAME
    end

    PerformHttpRequest(webhook, function(statusCode, response)
        if statusCode ~= 200 and statusCode ~= 201 and statusCode ~= 204 then
            logDiscordHttpFailure('Webhook log', statusCode, response)
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

-- Export: Send Discord message with custom fields
function sendDiscordMessage(title, description, color, extraFields)
    if not Config.enableWebhook then
        if canUseBotLogging() then
            postToCategoryForum('admin_audit', {
                title = tostring(title or 'DG Log'),
                description = tostring(description or 'No message provided.'),
                color = color or 3447003,
                fields = type(extraFields) == 'table' and extraFields or {}
            })
        end
        return
    end

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
    
    local payload = { embeds = embed }
    if WEBHOOK_THREAD_NAME ~= '' then
        payload.thread_name = WEBHOOK_THREAD_NAME
    end

    PerformHttpRequest(DISCORD_WEBHOOK, function(statusCode, response)
        if statusCode ~= 200 and statusCode ~= 201 and statusCode ~= 204 then
            logDiscordHttpFailure('Webhook embed', statusCode, response)
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
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

    runStartupThreadCleanup(function()
        if (Config.enableWebhook and not isPlaceholder(DISCORD_WEBHOOK, 'PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE')) or canUseBotLogging() then
            logToDiscord('DG Discord Bot Online', 'Monitoring users', 5763719)
        end
    end)
end)

-- ==========================================
-- DISCORD BOT API & FORUM THREADS
-- ==========================================

-- Export: Get or create a player's dedicated forum thread
function getOrCreatePlayerThread(license, playerName, callback)
    license = coerceString(license, 'unknown')
    playerName = coerceString(playerName, 'Unknown Player')

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
    license = coerceString(license, 'unknown')
    playerName = coerceString(playerName, 'Unknown Player')
    embeds = coerceTable(embeds)

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
    -- Backward/defensive compatibility: some callers may pass only a payload table.
    if type(category) == 'table' and payload == nil then
        payload = category
        category = payload.category or payload.logCategory or payload.channel or payload.type or 'general'
    end

    if type(category) ~= 'string' or category == '' then
        category = 'general'
    end

    payload = type(payload) == 'table' and payload or {}
    local embeds = payload.embeds
    if not embeds then
        embeds = {
            {
                title = payload.title or getDefaultCategoryPostTitle(category),
                description = payload.description or payload.message or 'No message provided.',
                color = payload.color or 3447003,
                fields = payload.fields or {},
                footer = { text = payload.footerText or 'DG Logging' },
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
            }
        }
    end

    -- Keep one canonical payload shape for all transport paths.
    payload.embeds = payload.embeds or embeds

    if shouldUseWebhookTransportFirst(category) then
        fallbackToWebhook(category, payload)
        return
    end

    getOrCreateCategoryThread(category, payload, function(threadId, cacheKey)
        if not threadId then
            print('^1[DG-Discord] Bot thread unavailable for category ' .. tostring(category) .. '.^0')
            fallbackToWebhook(category, payload)
            return
        end

        local requestBody = json.encode({ embeds = embeds })
        local postUrl = 'https://discord.com/api/v10/channels/' .. tostring(threadId) .. '/messages'

        PerformHttpRequest(postUrl, function(statusCode, response)
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
                logDiscordHttpFailure('Category post (' .. tostring(category) .. ')', statusCode, response)
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
    playerName = coerceString(playerName, 'Unknown Player')
    reason = coerceString(reason, 'unknown')
    weight = coerceString(weight, 'low')
    score = coerceNumber(score, 0)
    scoreIncrease = coerceNumber(scoreIncrease, 0)
    details = coerceTable(details)
    identifiers = coerceTable(identifiers)

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
        { name = '🎯 Score', value = '**' .. tostring(score) .. '**/8 *(+' .. tostring(scoreIncrease) .. ')*', inline = true },
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
    playerName = coerceString(playerName, 'Unknown Player')
    license = coerceString(license, 'N/A')
    identifiers = coerceTable(identifiers)
    serverId = coerceNumber(serverId, 'N/A')

    local pingValue = ping
    if type(pingValue) == 'table' then
        pingValue = pingValue.ping or pingValue.value or pingValue.latency
    end
    pingValue = tostring(pingValue or 'N/A')

    local steamId = coerceString(identifiers.steamid, 'N/A')
    local discordIdValue = coerceString(identifiers.discord, 'N/A')

    local fields = {
        { name = '🎮 Player Name', value = '**' .. playerName .. '**', inline = true },
        { name = '🔢 Server ID', value = '`' .. tostring(serverId or 'N/A') .. '`', inline = true },
        { name = '📶 Ping', value = pingValue .. ' ms', inline = true },
    }
    
    table.insert(fields, { name = '🔑 FiveM License', value = '```' .. license .. '```', inline = false })
    
    if steamId ~= '' and steamId ~= 'N/A' then
        table.insert(fields, { name = '🎯 Steam ID', value = '`' .. steamId .. '`', inline = true })
    else
        table.insert(fields, { name = '🎯 Steam ID', value = 'Not Linked', inline = true })
    end
    
    if discordIdValue ~= '' and discordIdValue ~= 'N/A' then
        local discordId = discordIdValue:gsub('discord:', '')
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

