fx_version 'cerulean'
game 'gta5'

-- リソース情報
name        'umistory'
description 'CR海物語 パチンコ (QBCore対応)'
author      'FSC'
version     '1.0.0'

-- 共有スクリプト（クライアント＆サーバー両方で読み込む）
shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua',
}

-- サーバースクリプト
server_scripts {
    'server/main.lua',
}

-- クライアントスクリプト
client_scripts {
    'client/main.lua',
}

-- NUIファイル
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    -- Matter.js はCDNから読み込むため不要（オフライン環境ではここに追加）
}
