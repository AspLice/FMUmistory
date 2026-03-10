--[[
    server/main.lua - CR海物語 サーバーサイドメインスクリプト

    責務:
      - プレイヤーの玉数・資金管理（QBCore）
      - チャッカー入賞イベントの受信とバリデーション（チート対策）
      - 抽選処理（大当たり / ハズレ / リーチ演出種別の決定）
      - 確変状態のサーバー管理
      - 大当たりラウンド進行と払い出し処理
]]

local QBCore = exports['qb-core']:GetCoreObject()

-- =========================================================
-- プレイヤー状態テーブル（サーバー側でのみ保持）
-- =========================================================
-- PlayerStates[source] = {
--   ballCount        : number  -- 現在の持ち玉数
--   isKakuhen        : bool    -- 確変中か
--   isInJackpot      : bool    -- 大当たりラウンド中か
--   currentRound     : number  -- 現在のラウンド番号
--   totalRoundBalls  : number  -- 今回の大当たりで獲得した玉数
--   lastChakkerTime  : number  -- 最後にチャッカー入賞通知を受信したサーバー時刻(os.clock)
--   chakkerCountMin  : number  -- 直近1分間のチャッカー入賞回数
--   chakkerMinStart  : number  -- 1分集計の起点時刻
--   violations       : number  -- チート違反カウント
-- }
local PlayerStates = {}

-- =========================================================
-- ユーティリティ関数
-- =========================================================

--- プレイヤー状態を初期化する
local function initPlayerState(src)
    PlayerStates[src] = {
        ballCount       = 0,
        isKakuhen       = false,
        isInJackpot     = false,
        currentRound    = 0,
        totalRoundBalls = 0,
        lastChakkerTime = 0,
        chakkerCountMin = 0,
        chakkerMinStart = os.clock(),
        violations      = 0,
    }
    return PlayerStates[src]
end

--- プレイヤー状態を取得（なければ初期化）
local function getState(src)
    if not PlayerStates[src] then
        return initPlayerState(src)
    end
    return PlayerStates[src]
end

--- プレイヤーを切断時にクリーンアップ
AddEventHandler('playerDropped', function()
    local src = source
    PlayerStates[src] = nil
end)

--- QBCoreプレイヤーオブジェクトを取得（nil安全）
local function getPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

--- 重み付きランダム選択 (weights: {30, 70} → 30%/70%)
local function weightedRandom(choices, weights)
    local total = 0
    for _, w in ipairs(weights) do total = total + w end
    local r = math.random(1, total)
    local cum = 0
    for i, w in ipairs(weights) do
        cum = cum + w
        if r <= cum then return choices[i] end
    end
    return choices[#choices]
end

--- セキュリティ違反を記録し、閾値超過時にキック
local function recordViolation(src, reason)
    local state = getState(src)
    state.violations = state.violations + 1
    print(('[umistory] チート検知 src=%d reason=%s violations=%d'):format(src, reason, state.violations))

    -- クライアントへ警告通知
    TriggerClientEvent('umistory:securityWarning', src, reason, state.violations)

    if state.violations >= Config.Security.maxViolations then
        -- BANが設定されている場合はBANコマンドを発行（要権限）
        if Config.Security.banMinutes > 0 then
            -- QBCoreのban機能を使用（バン機能の実装はサーバーに依存）
            local Player = getPlayer(src)
            if Player then
                -- 例: exports['qb-core']:BanPlayer(src, banMinutes * 60)
                -- ここでは汎用的にDropPlayerを使用
                DropPlayer(src, ('[umistory] チート行為を検知しました。%d分間ご利用いただけません。'):format(Config.Security.banMinutes))
            end
        else
            DropPlayer(src, '[umistory] チート行為を検知しました。')
        end
    end
end

-- =========================================================
-- セキュリティ: チャッカー入賞バリデーション
-- =========================================================
--- 入賞通知が正当かを検証する
--- @return bool, string  有効か, 理由
local function validateChakker(src)
    local state = getState(src)
    local now = os.clock()

    -- (1) 最小間隔チェック（物理的にあり得ない連打）
    local elapsed = now - state.lastChakkerTime
    if elapsed < Config.Security.minChakkerIntervalSec then
        return false, ('入賞間隔が短すぎます (%.3f秒)'):format(elapsed)
    end

    -- (2) 1分あたりの入賞回数チェック
    local minElapsed = now - state.chakkerMinStart
    if minElapsed >= 60 then
        -- 集計ウィンドウをリセット
        state.chakkerCountMin = 0
        state.chakkerMinStart = now
    end
    state.chakkerCountMin = state.chakkerCountMin + 1
    if state.chakkerCountMin > Config.Security.maxChakkerPerMinute then
        return false, ('1分間の入賞回数超過 (%d回)'):format(state.chakkerCountMin)
    end

    -- (3) 持ち玉チェック（玉がないのに入賞通知は不正）
    if state.ballCount < Config.BallsPerChakker then
        return false, ('持ち玉不足 (残%d玉)'):format(state.ballCount)
    end

    -- (4) 大当たりラウンド中の入賞は受け付けない
    if state.isInJackpot then
        return false, '大当たりラウンド中のため無効'
    end

    return true, 'ok'
end

-- =========================================================
-- 抽選ロジック
-- =========================================================

--- 大当たり抽選を行い、結果オブジェクトを返す
--- @param isKakuhen bool 確変中か
--- @return table result
local function doLottery(isKakuhen)
    local denom = isKakuhen
        and Config.Lottery.kakuhenDenominator
        or  Config.Lottery.normalDenominator

    -- 大当たり判定
    local isJackpot = (math.random(1, denom) == 1)

    -- リーチ発生判定（ハズレ時のみ）
    local reachType = 'none'
    local isGyogun = false

    if not isJackpot then
        local reachDenom = isKakuhen
            and Config.Lottery.reachProbabilityKakuhen
            or  Config.Lottery.reachProbabilityNormal
        local hasReach = (math.random(1, reachDenom) == 1)
        if hasReach then
            -- ノーマル or スーパーリーチ判定
            local isSuper = (math.random(1, Config.Lottery.superReachDenominator) == 1)
            reachType = isSuper and 'super' or 'normal'
            -- 魚群演出判定（スーパーリーチ時）
            if isSuper then
                isGyogun = (math.random(1, Config.Lottery.gyogunProbabilityOnSuperReach) == 1)
            end
        end
    else
        -- 大当たり時はスーパーリーチからの当たり演出とする
        reachType = 'super'
        isGyogun = (math.random(1, 2) == 1)  -- 50%で魚群演出付き当たり
    end

    -- 大当たり図柄の決定（当たりの場合のみ）
    local symbol = nil
    local isKakuhenWin = false
    local rounds = 0

    if isJackpot then
        -- 図柄: 1〜9 からランダム（奇数=確変、偶数=通常）
        symbol = math.random(1, 9)
        isKakuhenWin = (symbol % 2 == 1)  -- 奇数なら確変当たり

        -- ラウンド数の決定
        if isKakuhenWin then
            rounds = Config.Jackpot.kakuhenRounds[math.random(#Config.Jackpot.kakuhenRounds)]
        else
            rounds = weightedRandom(Config.Jackpot.normalRounds, Config.Jackpot.normalRoundsWeight)
        end
    end

    -- ハズレ図柄（3つのスロットをバラバラに）
    local reelResults = {0, 0, 0}
    if isJackpot then
        reelResults = {symbol, symbol, symbol}
    else
        -- リーチの場合は最初の2つを同じにする
        if reachType ~= 'none' then
            local s = math.random(1, 9)
            local third = s
            while third == s do
                third = math.random(1, 9)
            end
            reelResults = {s, s, third}
        else
            -- 完全バラバラ
            local s1 = math.random(1, 9)
            local s2 = s1
            while s2 == s1 do s2 = math.random(1, 9) end
            local s3 = s1
            while s3 == s1 do s3 = math.random(1, 9) end
            reelResults = {s1, s2, s3}
        end
    end

    return {
        isJackpot    = isJackpot,
        reachType    = reachType,      -- 'none', 'normal', 'super'
        isGyogun     = isGyogun,       -- 魚群演出フラグ
        reelResults  = reelResults,    -- {reel1, reel2, reel3}
        isKakuhenWin = isKakuhenWin,   -- 確変当たりか
        rounds       = rounds,         -- 大当たりラウンド数
    }
end

-- =========================================================
-- チャッカー入賞イベント受信
-- =========================================================
RegisterNetEvent('umistory:chakkerHit', function()
    local src = source
    local state = getState(src)

    -- バリデーション
    local valid, reason = validateChakker(src)
    if not valid then
        recordViolation(src, reason)
        return
    end

    -- 入賞時刻を更新
    state.lastChakkerTime = os.clock()

    -- 玉を消費
    state.ballCount = state.ballCount - Config.BallsPerChakker

    -- 抽選実行（サーバー側のみ）
    local result = doLottery(state.isKakuhen)

    print(('[umistory] src=%d 抽選結果: %s リーチ=%s 魚群=%s 図柄={%d,%d,%d}'):format(
        src,
        result.isJackpot and '大当たり' or 'ハズレ',
        result.reachType,
        tostring(result.isGyogun),
        result.reelResults[1], result.reelResults[2], result.reelResults[3]
    ))

    -- 抽選結果をクライアントへ送信（演出用）
    TriggerClientEvent('umistory:lotteryResult', src, {
        reachType   = result.reachType,
        isGyogun    = result.isGyogun,
        reelResults = result.reelResults,
        isJackpot   = result.isJackpot,
        ballCount   = state.ballCount,
    })

    -- 大当たりの場合はラウンド処理を開始
    if result.isJackpot then
        startJackpot(src, result)
    end
end)

-- =========================================================
-- 大当たりラウンド処理
-- =========================================================

--- 大当たり処理を開始する
function startJackpot(src, result)
    local state = getState(src)
    state.isInJackpot     = true
    state.currentRound    = 0
    state.totalRoundBalls = 0

    -- クライアントへ大当たり開始通知
    TriggerClientEvent('umistory:jackpotStart', src, {
        rounds       = result.rounds,
        isKakuhenWin = result.isKakuhenWin,
    })

    -- 非同期でラウンドを順次消化する
    Citizen.CreateThread(function()
        for round = 1, result.rounds do
            state.currentRound = round

            -- ラウンド開始をクライアントに通知
            TriggerClientEvent('umistory:roundStart', src, round, result.rounds)

            -- 1ラウンド分の時間待機（アタッカー開放）
            Citizen.Wait(Config.Jackpot.roundDurationSec * 1000)

            -- ラウンド払い出し玉数を加算
            local earnedBalls = Config.Jackpot.ballsPerRound
            state.ballCount = state.ballCount + earnedBalls
            state.totalRoundBalls = state.totalRoundBalls + earnedBalls

            -- ラウンド終了を通知
            TriggerClientEvent('umistory:roundEnd', src, round, state.ballCount)

            -- ラウンドインターバル
            Citizen.Wait(1500)
        end

        -- 全ラウンド終了 → 払い出し処理
        finishJackpot(src, result)
    end)
end

--- 大当たり全ラウンド終了時の処理
function finishJackpot(src, result)
    local state = getState(src)
    state.isInJackpot = false

    -- 確変状態の更新
    state.isKakuhen = result.isKakuhenWin

    -- 合計獲得玉を現金に換算して支払い
    local totalBalls = state.totalRoundBalls
    local cashPayout = totalBalls * Config.Payout.ballToCashRate

    -- 確変当たりボーナス
    if result.isKakuhenWin then
        cashPayout = cashPayout * Config.Payout.kakuhenBonusMultiplier
    end

    -- サーバー側で資金を増加（QBCore）
    local Player = getPlayer(src)
    if Player then
        Player.Functions.AddMoney(Config.Payout.moneyType, math.floor(cashPayout), 'umistory-jackpot')
        print(('[umistory] src=%d 払い出し: %d玉 → $%d (確変:%s)'):format(
            src, totalBalls, math.floor(cashPayout), tostring(result.isKakuhenWin)
        ))
    end

    -- 終了をクライアントへ通知
    TriggerClientEvent('umistory:jackpotFinish', src, {
        totalBalls   = totalBalls,
        cashPayout   = math.floor(cashPayout),
        isKakuhen    = state.isKakuhen,
        ballCount    = state.ballCount,
    })
end

-- =========================================================
-- 玉の購入（セッション開始）
-- =========================================================
RegisterNetEvent('umistory:buyBalls', function(amount)
    local src = source
    amount = math.floor(tonumber(amount) or 0)

    -- 入力バリデーション
    if amount <= 0 or amount > Config.MaxBallsPerSession then
        TriggerClientEvent('umistory:notification', src, 'error', '購入数が不正です。')
        return
    end

    local Player = getPlayer(src)
    if not Player then return end

    -- 現金モード: プレイヤーから代金を引く
    local cost = amount * Config.BallCostCash
    local currentMoney = Player.PlayerData.money[Config.Payout.moneyType] or 0

    if currentMoney < cost then
        TriggerClientEvent('umistory:notification', src, 'error', ('所持金が不足しています ($%d 必要)'):format(cost))
        return
    end

    -- 代金を引く
    Player.Functions.RemoveMoney(Config.Payout.moneyType, cost, 'umistory-buy-balls')

    -- 状態初期化（セッション開始）
    initPlayerState(src)
    local state = getState(src)
    state.ballCount = amount

    print(('[umistory] src=%d 玉購入: %d玉 ($%d)'):format(src, amount, cost))

    -- クライアントへセッション開始を通知
    TriggerClientEvent('umistory:sessionStart', src, {
        ballCount = state.ballCount,
        cost      = cost,
    })
end)

-- =========================================================
-- 玉の換金（セッション終了）
-- =========================================================
RegisterNetEvent('umistory:cashOut', function()
    local src = source
    local state = getState(src)

    if not state or state.ballCount <= 0 then
        TriggerClientEvent('umistory:notification', src, 'error', '換金できる玉がありません。')
        return
    end

    if state.isInJackpot then
        TriggerClientEvent('umistory:notification', src, 'error', 'ラウンド中は換金できません。')
        return
    end

    local balls = state.ballCount
    local cashPayout = math.floor(balls * Config.Payout.ballToCashRate)

    -- 資金を追加
    local Player = getPlayer(src)
    if Player and cashPayout > 0 then
        Player.Functions.AddMoney(Config.Payout.moneyType, cashPayout, 'umistory-cashout')
    end

    print(('[umistory] src=%d 換金: %d玉 → $%d'):format(src, balls, cashPayout))

    -- セッションリセット
    initPlayerState(src)

    TriggerClientEvent('umistory:cashOutResult', src, {
        balls      = balls,
        cashPayout = cashPayout,
    })
end)

-- =========================================================
-- デバッグ: サーバーコンソールから状態確認
-- =========================================================
RegisterCommand('umistory_state', function(src, args)
    if src ~= 0 then return end  -- コンソールのみ
    local targetSrc = tonumber(args[1])
    if targetSrc and PlayerStates[targetSrc] then
        local s = PlayerStates[targetSrc]
        print(('=== umistory state [%d] ==='):format(targetSrc))
        print(('  玉数: %d'):format(s.ballCount))
        print(('  確変: %s'):format(tostring(s.isKakuhen)))
        print(('  ラウンド中: %s'):format(tostring(s.isInJackpot)))
        print(('  違反回数: %d'):format(s.violations))
    else
        print('プレイヤーが存在しないか、未プレイです。')
    end
end, true)
