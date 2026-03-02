fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dg-discord-bot'
description 'Discord Integration for DG Scripts - Webhooks & Bot API'
author 'DG-Scripts'
version '1.0.0'

dependency 'oxmysql'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/*.lua'
}

server_exports {
    'logToDiscord',
    'sendDiscordMessage',
    'postToPlayerThread',
    'getOrCreatePlayerThread',
    'buildDetectionEmbed',
    'buildPlayerInfoEmbed',
    'buildBanEmbed',
    'buildKickEmbed',
    'buildConnectionEmbed',
    'buildAdminActionEmbed',
    'buildWarningEmbed',
    'buildAISuggestionEmbed',
    'buildTransactionEmbed',
    'buildVehicleSpawnEmbed',
    'buildServerEventEmbed'
}
