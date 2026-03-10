--[[
    client/main.lua - CR海物語 クライアントサイドスクリプト

    責務:
      - インタラクション（近接でパチンコ台に話しかける）
      - NUI の開閉、サーバーイベントの中継
      - サーバーからの演出指示をNUIへ転送
]]

local QBCore = exports['qb-core']:GetCoreObject()

-- NUI表示状態フラグ
local isNUIOpen = false

-- =========================================================
-- NUI の開閉
-- =========================================================

--- NUIを開く
local function openNUI()
    if isNUIOpen then return end
    isNUIOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open' })
end

--- NUIを閉じる
local function closeNUI()
    if not isNUIOpen then return end
    isNUIOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

-- =========================================================
-- インタラクション: パチンコ台に近づいてキー押下
-- =========================================================

-- 最も近くにある台のインデックスを返す
local function getNearbyMachine()
    local playerCoords = GetEntityCoords(PlayerPedId())
    for i, machine in ipairs(Config.MachineLocations) do
        local dist = #(playerCoords - machine.coords)
        if dist <= Config.InteractDistance then
            return machine
        end
    end
    return nil
end

-- メインループ: 台の近くにいる間、インタラクションプロンプトを表示
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        if not isNUIOpen then
            local machine = getNearbyMachine()
            if machine then
                -- ヘルプテキスト表示
                BeginTextCommandDisplayHelp('STRING')
                AddTextComponentSubstringPlayerName(('~INPUT_CONTEXT~ %s を開始する'):format(machine.label))
                EndTextCommandDisplayHelp(0, false, false, -1)

                -- E キーでNUI開く
                if IsControlJustReleased(0, 38) then  -- E
                    openNUI()
                end
            end
        end

        -- Escape / バックスペースで閉じる（NUI側からも制御可）
        if isNUIOpen then
            if IsControlJustReleased(0, 177) or IsControlJustReleased(0, 200) then  -- Backspace / Escape
                closeNUI()
                -- サーバーへセッション終了通知（換金せずに離席）
                TriggerServerEvent('umistory:cashOut')
            end
        end
    end
end)

-- =========================================================
-- NUI コールバック: NUI側からのイベント受信
-- =========================================================

--- NUI → サーバー: 玉を購入してセッション開始
RegisterNUICallback('buyBalls', function(data, cb)
    local amount = tonumber(data.amount)
    TriggerServerEvent('umistory:buyBalls', amount)
    cb({ ok = true })
end)

--- NUI → サーバー: チャッカー入賞通知
RegisterNUICallback('chakkerHit', function(data, cb)
    TriggerServerEvent('umistory:chakkerHit')
    cb({ ok = true })
end)

--- NUI → サーバー: 換金してセッション終了
RegisterNUICallback('cashOut', function(data, cb)
    TriggerServerEvent('umistory:cashOut')
    cb({ ok = true })
end)

--- NUI → クライアント: NUIを閉じる
RegisterNUICallback('closeNUI', function(data, cb)
    closeNUI()
    cb({ ok = true })
end)

-- =========================================================
-- サーバー → クライアント → NUI: 状態転送イベント群
-- =========================================================

--- セッション開始（玉購入成功）
RegisterNetEvent('umistory:sessionStart', function(data)
    SendNUIMessage({ action = 'sessionStart', data = data })
end)

--- 抽選結果（演出指示）
RegisterNetEvent('umistory:lotteryResult', function(data)
    -- サーバーが決定した抽選結果をそのままNUIへ転送
    -- NUIは演出のみを行い、結果を改ざんできない
    SendNUIMessage({ action = 'lotteryResult', data = data })
end)

--- 大当たり開始
RegisterNetEvent('umistory:jackpotStart', function(data)
    SendNUIMessage({ action = 'jackpotStart', data = data })
end)

--- ラウンド開始
RegisterNetEvent('umistory:roundStart', function(round, totalRounds)
    SendNUIMessage({ action = 'roundStart', data = { round = round, totalRounds = totalRounds } })
end)

--- ラウンド終了（玉数更新）
RegisterNetEvent('umistory:roundEnd', function(round, ballCount)
    SendNUIMessage({ action = 'roundEnd', data = { round = round, ballCount = ballCount } })
end)

--- 全ラウンド終了・払い出し完了
RegisterNetEvent('umistory:jackpotFinish', function(data)
    SendNUIMessage({ action = 'jackpotFinish', data = data })
end)

--- 換金結果
RegisterNetEvent('umistory:cashOutResult', function(data)
    SendNUIMessage({ action = 'cashOutResult', data = data })
    -- NUIを閉じる
    closeNUI()
    -- 画面通知
    QBCore.Functions.Notify(
        ('換金完了: %d玉 → $%d'):format(data.balls, data.cashPayout),
        'success', 5000
    )
end)

--- セキュリティ警告（チート検知）
RegisterNetEvent('umistory:securityWarning', function(reason, count)
    SendNUIMessage({ action = 'securityWarning' })
    QBCore.Functions.Notify(
        '[警告] 不正な操作を検知しました。',
        'error', 5000
    )
    print(('[umistory] セキュリティ警告: %s (%d回目)'):format(reason, count))
end)

--- 汎用通知
RegisterNetEvent('umistory:notification', function(ntype, msg)
    QBCore.Functions.Notify(msg, ntype, 5000)
end)
