/**
 * script.js - CR海物語 NUIメインロジック
 *
 * 役割:
 *   - Matter.js を使った軽量2D物理演算（盤面・玉・釘・チャッカー）
 *   - ハンドル強度に応じた打ち出し制御
 *   - FiveMサーバーとのNUI通信（PostMessage / RegisterNuiCallback）
 *   - 抽選結果に基づくリーチ演出・魚群演出・スロットアニメーション
 */

'use strict';

// =====================================================
// ① レジストリ・定数
// =====================================================

const REEL_CELL_HEIGHT = 80;        // px - リールセル高さ
const REEL_SYMBOLS     = [1,2,3,4,5,6,7,8,9]; // 図柄
const BOARD_W          = 580;       // 盤面幅 px
const BOARD_H          = 600;       // 盤面高さ px

// チャッカー（入賞口）の中心座標（盤面内）
const CHAKKER_CENTER_X = BOARD_W / 2;
const CHAKKER_CENTER_Y = BOARD_H - 70;   // 下から70px付近
const CHAKKER_RADIUS   = 20;        // 当たり判定半径 px

// =====================================================
// ② アプリ状態
// =====================================================
const State = {
    sessionActive:  false,
    ballCount:      0,
    isKakuhen:      false,
    isLaunching:    false,      // 打ち出し中か
    isSpinning:     false,      // スロット回転中か
    isJackpot:      false,
    handleValue:    50,         // ハンドル強度 0〜100
    launchInterval: null,       // 打ち出しインターバルID
    lastChakkerMs:  0,          // 最後の入賞判定時刻（クライアント側でのスパム防止補助）
};

// =====================================================
// ③ UI要素の取得
// =====================================================
const $ = id => document.getElementById(id);
const elBallCount     = $('ball-count');
const elKakuhenStatus = $('kakuhen-status');
const elRoundStatus   = $('round-status');
const elHandleSlider  = $('handle-slider');
const elHandleValue   = $('handle-value');
const elBtnLaunch     = $('btn-launch');
const elBtnBuy        = $('btn-buy');
const elBtnCashout    = $('btn-cashout');
const elBtnClose      = $('btn-close');
const elBuyAmount     = $('buy-amount');
const elLcdScreen     = $('lcd-screen');
const elReachText     = $('reach-text');
const elJackpotBanner = $('jackpot-banner');
const elJackpotRounds = $('jackpot-rounds-label');
const elKakuhenBadge  = $('kakuhen-badge');
const elGyogunLayer   = $('gyogun-layer');
const elChakkerFlash  = $('chakker-flash');
const elRoundOverlay  = $('round-overlay');
const elRoundNumber   = $('round-number');
const elRoundSub      = $('round-sub');
const elCashoutModal  = $('cashout-modal');
const elCashoutResult = $('cashout-result');
const elBtnCashoutOk  = $('btn-cashout-ok');

// =====================================================
// ④ Matter.js セットアップ
// =====================================================

const { Engine, Render, Runner, Bodies, Body, World, Events, Vector } = Matter;

let engine, render, runner, world;

/**
 * 物理エンジンを初期化する。
 * パフォーマンス最適化のため:
 *  - constraintIterations=2（少なめで十分）
 *  - positionIterations=6
 *  - velocityIterations=4
 */
function initPhysics() {
    engine = Engine.create({
        gravity: { x: 0, y: 1.5 },       // パチンコっぽい重力
        constraintIterations: 2,
        positionIterations: 6,
        velocityIterations: 4,
    });
    world = engine.world;

    const canvas = $('physics-canvas');
    canvas.width  = BOARD_W;
    canvas.height = BOARD_H;

    render = Render.create({
        canvas: canvas,
        engine: engine,
        options: {
            width:       BOARD_W,
            height:      BOARD_H,
            background:  'transparent',
            wireframes:  false,      // テクスチャモード
            hasBounds:   false,
        },
    });

    Render.run(render);
    runner = Runner.create();
    Runner.run(runner, engine);

    // 壁（左・右・下）
    const wallOpts = { isStatic: true, render: { fillStyle: 'rgba(0,100,180,0.5)' } };
    World.add(world, [
        Bodies.rectangle(BOARD_W / 2, BOARD_H + 25, BOARD_W, 50, wallOpts),   // 床
        Bodies.rectangle(-25, BOARD_H / 2, 50, BOARD_H, wallOpts),             // 左壁
        Bodies.rectangle(BOARD_W + 25, BOARD_H / 2, 50, BOARD_H, wallOpts),   // 右壁
    ]);

    // 釘（ペグ）を規則的に配置
    buildPegs();

    // チャッカー（センサー）を作成
    const chakker = Bodies.circle(
        CHAKKER_CENTER_X, CHAKKER_CENTER_Y, CHAKKER_RADIUS,
        {
            isStatic: true,
            isSensor: true,
            label: 'chakker',
            render: { fillStyle: 'rgba(255,200,0,0.6)', strokeStyle: '#ffd700', lineWidth: 2 },
        }
    );
    World.add(world, chakker);

    // 衝突イベント: チャッカー判定
    Events.on(engine, 'collisionStart', onCollision);
}

/**
 * 釘（ペグ）を六方格子状に配置する。
 * 釘の数を絞ることで物理オブジェクト数を最小化。
 */
function buildPegs() {
    const pegOpts = {
        isStatic: true,
        render: { fillStyle: '#2080c0', strokeStyle: '#40b0e0', lineWidth: 1 },
        restitution: 0.3,
        friction: 0.05,
    };
    const rows = 9;
    const cols = 8;
    const offsetY = 230;    // 液晶画面より下から釘を配置
    const spacingX = 58;
    const spacingY = 42;

    for (let r = 0; r < rows; r++) {
        const colCount = (r % 2 === 0) ? cols : cols - 1;
        const xStart = (r % 2 === 0) ? 40 : 70;
        for (let c = 0; c < colCount; c++) {
            const x = xStart + c * spacingX;
            const y = offsetY + r * spacingY;
            World.add(world, Bodies.circle(x, y, 6, pegOpts));
        }
    }
}

/** 衝突検知コールバック */
function onCollision(event) {
    event.pairs.forEach(pair => {
        const { bodyA, bodyB } = pair;
        const isChakker = bodyA.label === 'chakker' || bodyB.label === 'chakker';
        const isBall    = bodyA.label === 'ball'    || bodyB.label === 'ball';

        if (isChakker && isBall) {
            // チャッカーに入賞した玉を少し後で削除（見た目のため）
            const ballBody = bodyA.label === 'ball' ? bodyA : bodyB;
            setTimeout(() => {
                World.remove(world, ballBody);
            }, 120);

            // サーバーへ入賞通知（クライアント側でのミリ秒スロットル補助）
            const now = Date.now();
            if (now - State.lastChakkerMs >= 280 && State.sessionActive && !State.isSpinning) {
                State.lastChakkerMs = now;
                onChakkerHit();
            }
        }
    });
}

// =====================================================
// ⑤ 玉の打ち出しロジック
// =====================================================

/**
 * ハンドル強度に応じた初速ベクトルで玉を発射する。
 * 弱め: 左下方向、強め: 右方向（パチンコのハンドル特性を再現）
 */
function launchBall() {
    if (!State.sessionActive || State.ballCount <= 0) return;

    const power  = State.handleValue / 100;                  // 0.0 〜 1.0
    const speed  = 12 + power * 14;                          // 12〜26 px/frame

    // 打ち出し角度: 右上方向、強度で微調整
    const angleDeg = -75 + power * 30;                       // -75°〜-45°
    const angleRad = (angleDeg * Math.PI) / 180;
    const vx = Math.cos(angleRad) * speed;
    const vy = Math.sin(angleRad) * speed;

    const ball = Bodies.circle(
        BOARD_W - 30,              // 右端（打ち出しレーン）から発射
        BOARD_H - 30,
        8,
        {
            label:       'ball',
            restitution: 0.45,
            friction:    0.02,
            frictionAir: 0.005,
            render: {
                fillStyle:   '#c0e8ff',
                strokeStyle: '#80c0ff',
                lineWidth:   1,
            },
        }
    );

    World.add(world, ball);
    Body.setVelocity(ball, { x: vx, y: vy });

    // 画面外に落ちた玉を遅延削除（パフォーマンス）
    setTimeout(() => {
        if (world.bodies.includes(ball)) {
            World.remove(world, ball);
        }
    }, 5000);
}

/** 打ち出しを開始/停止するトグル */
function toggleLaunch() {
    if (!State.sessionActive) return;

    State.isLaunching = !State.isLaunching;
    if (State.isLaunching) {
        elBtnLaunch.textContent = '打ち出し 停止';
        elBtnLaunch.classList.add('active');
        // ハンドル強度に応じた発射間隔（強いほど速く連射）
        const intervalMs = () => 400 - State.handleValue * 2.5;  // 150〜400 ms
        const scheduleLaunch = () => {
            if (!State.isLaunching) return;
            launchBall();
            State.launchInterval = setTimeout(scheduleLaunch, intervalMs());
        };
        scheduleLaunch();
    } else {
        elBtnLaunch.textContent = '打ち出し 開始';
        elBtnLaunch.classList.remove('active');
        clearTimeout(State.launchInterval);
    }
}

// =====================================================
// ⑥ スロットリール
// =====================================================

/** リールセルDOM群を初期化する（3リール × (REEL_SYMBOLS + 余裕分) セル）*/
function initReels() {
    for (let i = 0; i < 3; i++) {
        const strip = $(`strip-${i}`);
        strip.innerHTML = '';
        // 充分な数のセルを連結してループ回転に見せる
        const symbols = [...REEL_SYMBOLS, ...REEL_SYMBOLS, ...REEL_SYMBOLS];
        symbols.forEach(num => {
            const cell = document.createElement('div');
            cell.className = 'reel-cell' + (num % 2 === 1 ? ' kakuhen' : '');
            cell.textContent = num;
            strip.appendChild(cell);
        });
        strip.style.transform = 'translateY(0px)';
    }
}

/**
 * 1リールをアニメーション停止させる。
 * @param {number} reelIdx  - リール番号 (0,1,2)
 * @param {number} symbol   - 停止する図柄 (1〜9)
 * @param {number} delayMs  - 停止開始の遅延
 * @returns {Promise}       - 停止完了後に解決
 */
function stopReel(reelIdx, symbol, delayMs) {
    return new Promise(resolve => {
        const strip = $(`strip-${reelIdx}`);

        // 高速スクロールアニメーション（CSS animation API）
        strip.style.transition = 'none';
        strip.style.transform  = 'translateY(-720px)';  // 高速回転中の初期位置

        // 停止目標: SYMBOLが0番セル位置に来るようにオフセット計算
        const symbolIndex    = REEL_SYMBOLS.indexOf(symbol);  // 0〜8
        const targetOffsetY  = -(symbolIndex * REEL_CELL_HEIGHT);

        setTimeout(() => {
            // スムーズに目標位置へ
            strip.style.transition = `transform ${delayMs < 2000 ? 0.5 : 1.0}s cubic-bezier(0.17, 0.67, 0.35, 1.0)`;
            strip.style.transform  = `translateY(${targetOffsetY}px)`;

            strip.addEventListener('transitionend', () => resolve(), { once: true });
        }, 80);
    });
}

/**
 * スロット演出を開始し、サーバー決定の結果で停止させる。
 * @param {object} result - { reachType, isGyogun, reelResults[3], isJackpot }
 */
async function playSlotAnimation(result) {
    if (State.isSpinning) return;
    State.isSpinning = true;

    const { reachType, isGyogun, reelResults, isJackpot } = result;

    // スロット高速回転開始（CSSでシミュレート）
    for (let i = 0; i < 3; i++) {
        const strip = $(`strip-${i}`);
        strip.style.transition = 'transform 0.2s linear';
        strip.style.transform  = 'translateY(-720px)';
        // 継続ループは CSS animation に委ねる
        strip.style.animation  = `reelSpin 0.15s linear infinite`;
    }

    // 魚群演出（スーパーリーチ時）
    if ((reachType === 'super') && isGyogun) {
        setTimeout(() => showGyogun(), 600);
    }

    // リーチテキスト
    if (reachType !== 'none') {
        setTimeout(() => {
            elReachText.textContent = reachType === 'super' ? '🌊 スーパーリーチ！' : '⭐ リーチ！';
            elReachText.classList.remove('hidden');
        }, 800);
    }

    // リール停止スケジュール
    const stopDelays = getStopDelays(reachType);

    // 1列目停止
    for (let i = 0; i < 3; i++) {
        const strip = $(`strip-${i}`);
        strip.style.animation = '';
    }

    await delay(stopDelays[0]);
    await stopReel(0, reelResults[0], 500);

    await delay(stopDelays[1]);
    await stopReel(1, reelResults[1], 500);

    // リーチの場合は3列目を引き伸ばす
    if (reachType !== 'none') {
        elReachText.textContent = reachType === 'super'
            ? '🌊 スーパーリーチ！ ラストチャンス！'
            : '⭐ リーチ！';
    }

    await delay(stopDelays[2]);
    await stopReel(2, reelResults[2], reachType !== 'none' ? 1000 : 500);

    // リーチテキストを消す
    elReachText.classList.add('hidden');

    State.isSpinning = false;

    if (isJackpot) {
        // 大当たりバナーはサーバーイベント(jackpotStart)受信時に表示
    }
}

/** リーチ種別ごとの停止ディレイ（ms） */
function getStopDelays(reachType) {
    switch (reachType) {
        case 'super':  return [600,  1200, 8000];
        case 'normal': return [600,  1000, 4000];
        default:       return [400,   700, 1000];
    }
}

// =====================================================
// ⑦ 演出関数
// =====================================================

/** チャッカー入賞フラッシュ */
function flashChakker() {
    elChakkerFlash.classList.remove('hidden');
    setTimeout(() => elChakkerFlash.classList.add('hidden'), 450);
}

/** 魚群演出 */
function showGyogun() {
    const fishGroup = elGyogunLayer.querySelector('.fish-group');
    if (!fishGroup) return;

    elGyogunLayer.classList.remove('hidden');
    // アニメーション時間を動的に設定（4秒で右端から左端へ）
    fishGroup.style.animation = 'fishSwim 3.5s linear forwards';
    fishGroup.style.right     = '-400px';

    setTimeout(() => {
        elGyogunLayer.classList.add('hidden');
        fishGroup.style.animation = '';
    }, 4000);
}

/** ラウンドオーバーレイ表示 */
function showRoundOverlay(round, totalRounds) {
    elRoundNumber.textContent = round;
    elRoundSub.textContent    = `/ ${totalRounds} ROUND`;
    elRoundOverlay.classList.remove('hidden');
    setTimeout(() => elRoundOverlay.classList.add('hidden'), 2200);
}

/** 大当たりバナー表示 */
function showJackpotBanner(rounds, isKakuhenWin) {
    elJackpotRounds.textContent = `${rounds}R ${isKakuhenWin ? '確変' : '通常'}大当たり`;
    elJackpotBanner.classList.remove('hidden');
    elBtnLaunch.disabled = true;
}

/** 大当たりバナー非表示 */
function hideJackpotBanner() {
    elJackpotBanner.classList.add('hidden');
    elBtnLaunch.disabled = false;
}

// =====================================================
// ⑧ UIステータス更新
// =====================================================

function updateBallCount(count) {
    State.ballCount      = count;
    elBallCount.textContent = count;
}

function updateKakuhen(isKakuhen) {
    State.isKakuhen       = isKakuhen;
    elKakuhenStatus.textContent = isKakuhen ? 'ON' : 'OFF';
    elKakuhenStatus.classList.toggle('on', isKakuhen);
    elKakuhenBadge.classList.toggle('hidden', !isKakuhen);
}

// =====================================================
// ⑨ サーバーへの通知（NUI Callbacks）
// =====================================================

/** サーバーコールバックを呼び出すユーティリティ */
function nuiPost(action, data = {}) {
    return fetch(`https://umistory/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    });
}

/** チャッカー入賞 → サーバー通知 */
function onChakkerHit() {
    flashChakker();
    nuiPost('chakkerHit');
}

// =====================================================
// ⑩ サーバーからのメッセージ受信 (window.addEventListener)
// =====================================================

window.addEventListener('message', event => {
    const { action, data } = event.data || {};

    switch (action) {

        case 'open':
            document.body.style.display = 'block';
            break;

        case 'close':
            document.body.style.display = 'none';
            break;

        case 'sessionStart':
            State.sessionActive = true;
            updateBallCount(data.ballCount);
            updateKakuhen(false);
            elRoundStatus.textContent = '-';
            break;

        case 'lotteryResult':
            updateBallCount(data.ballCount);
            playSlotAnimation(data);
            break;

        case 'jackpotStart':
            State.isJackpot = true;
            showJackpotBanner(data.rounds, data.isKakuhenWin);
            // 打ち出しを自動停止
            if (State.isLaunching) toggleLaunch();
            break;

        case 'roundStart':
            showRoundOverlay(data.round, data.totalRounds);
            elRoundStatus.textContent = `${data.round}/${data.totalRounds}R`;
            break;

        case 'roundEnd':
            updateBallCount(data.ballCount);
            break;

        case 'jackpotFinish':
            State.isJackpot = false;
            hideJackpotBanner();
            updateBallCount(data.ballCount);
            updateKakuhen(data.isKakuhen);
            elRoundStatus.textContent = '-';
            break;

        case 'cashOutResult':
            showCashoutModal(data.balls, data.cashPayout);
            State.sessionActive = false;
            updateBallCount(0);
            updateKakuhen(false);
            break;

        case 'securityWarning':
            // チート検知: 強制的に打ち出しを停止
            if (State.isLaunching) toggleLaunch();
            break;
    }
});

// =====================================================
// ⑪ 換金モーダル
// =====================================================

function showCashoutModal(balls, cash) {
    elCashoutResult.innerHTML = `
        <div>獲得玉数: <strong>${balls}玉</strong></div>
        <div>換金額: <strong>$${cash.toLocaleString()}</strong></div>
    `;
    elCashoutModal.classList.remove('hidden');
}

elBtnCashoutOk.addEventListener('click', () => {
    elCashoutModal.classList.add('hidden');
    nuiPost('closeNUI');
});

// =====================================================
// ⑫ UIイベントリスナー
// =====================================================

/** ハンドルスライダー */
elHandleSlider.addEventListener('input', () => {
    State.handleValue     = parseInt(elHandleSlider.value, 10);
    elHandleValue.textContent = State.handleValue;
});

/** 打ち出しボタン */
elBtnLaunch.addEventListener('click', toggleLaunch);

/** 玉購入ボタン */
elBtnBuy.addEventListener('click', () => {
    const amount = parseInt(elBuyAmount.value, 10);
    if (isNaN(amount) || amount <= 0) return;
    nuiPost('buyBalls', { amount });
});

/** 換金ボタン */
elBtnCashout.addEventListener('click', () => {
    if (!State.sessionActive || State.isJackpot) return;
    nuiPost('cashOut');
});

/** 閉じるボタン */
elBtnClose.addEventListener('click', () => {
    if (State.isLaunching) toggleLaunch();
    nuiPost('closeNUI');
});

// =====================================================
// ⑬ 補助ユーティリティ
// =====================================================

/** Promiseベースのsleep */
function delay(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

// =====================================================
// ⑭ cssアニメーション: reelSpin をJS挿入
// =====================================================
(function injectReelSpinKeyframe() {
    const style = document.createElement('style');
    style.textContent = `
        @keyframes reelSpin {
            0%   { transform: translateY(0px); }
            100% { transform: translateY(-${REEL_CELL_HEIGHT * REEL_SYMBOLS.length}px); }
        }
    `;
    document.head.appendChild(style);
})();

// =====================================================
// ⑮ 初期化
// =====================================================
(function main() {
    // デフォルトは非表示（FiveMがNUIを開いたタイミングで表示）
    document.body.style.display = 'none';

    initPhysics();
    initReels();

    console.log('[umistory] NUI 初期化完了');
})();
