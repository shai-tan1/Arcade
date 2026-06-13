#!/usr/bin/env bash
# Adds the Frequency game to crystal-v2.0 (run AFTER apply-games.sh).
# Run from the repo "main/" directory:  bash apply-game-frequency.sh
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then echo "ERROR: run from your repo's main/ directory"; exit 1; fi
if [ ! -f backend/src/modules/game/games.routes.js ]; then echo "ERROR: run apply-games.sh first (games framework missing)"; exit 1; fi
if grep -q "frequency" backend/src/modules/game/engine/index.js 2>/dev/null; then echo "Frequency already added. Skipping."; exit 0; fi

mkdir -p backend/src/modules/game/engine frontend/src/pages/GamesPage/games

cat > backend/src/modules/game/engine/frequency.js << 'FREOF'
// src/modules/game/engine/frequency.js
// A tone is played; the player guesses its frequency in Hz. Closest guess scores higher.

import { mulberry32 } from './prng.js';

const ROUNDS = 5;
const MIN_HZ = 120;
const MAX_HZ = 3000;
const MAX_OCTAVES = 2; // beyond ~2 octaves off = 0 points

function genFreq(rng) {
    // log-uniform pick so low/high tones are equally likely perceptually
    return Math.round(MIN_HZ * Math.pow(MAX_HZ / MIN_HZ, rng()));
}

export const frequency = {
    key: 'frequency',
    rounds: ROUNDS,

    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const target = genFreq(rng);
            // The tone (target) is sent so the client can play it; the guess is scored against it.
            rounds.push({ prompt: { type: 'frequency', target }, solution: target });
        }
        return rounds;
    },

    score(solution, answer) {
        const g = typeof answer === 'number' ? answer : parseFloat(answer);
        if (!Number.isFinite(g) || g <= 0) return 0;
        const octaves = Math.abs(Math.log2(g / solution));
        return Math.round(Math.max(0, 100 * (1 - octaves / MAX_OCTAVES)));
    }
};
FREOF
echo "  wrote frequency.js"

cat > frontend/src/pages/GamesPage/games/Frequency.jsx << 'FREOF'
// frontend/src/pages/GamesPage/games/Frequency.jsx

import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';

import styles from './Frequency.module.css';

const ROUND_SECONDS = 25;
const MIN_HZ = 50;
const MAX_HZ = 5000;

function posToFreq(pos) {
  return Math.round(MIN_HZ * Math.pow(MAX_HZ / MIN_HZ, pos / 1000));
}

function FrequencyRound({ target, roundIndex, onSubmit, submitting }) {
  const { t } = useTranslation();
  const [pos, setPos] = useState(500);
  const [seconds, setSeconds] = useState(ROUND_SECONDS);
  const submittedRef = useRef(false);
  const ctxRef = useRef(null);

  const guessHz = posToFreq(pos);

  useEffect(() => {
    const id = setInterval(() => setSeconds((s) => s - 1), 1000);
    return () => clearInterval(id);
  }, [roundIndex]);

  const submit = () => {
    if (submittedRef.current) return;
    submittedRef.current = true;
    onSubmit(roundIndex, guessHz);
  };

  useEffect(() => {
    if (seconds <= 0) submit();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seconds]);

  useEffect(() => {
    return () => {
      if (ctxRef.current && ctxRef.current.state !== 'closed') {
        ctxRef.current.close().catch(() => {});
      }
    };
  }, []);

  const playTone = () => {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      const ctx = ctxRef.current && ctxRef.current.state !== 'closed' ? ctxRef.current : new Ctx();
      ctxRef.current = ctx;
      if (ctx.state === 'suspended') ctx.resume();
      const now = ctx.currentTime;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = target;
      gain.gain.setValueAtTime(0, now);
      gain.gain.linearRampToValueAtTime(0.2, now + 0.02);
      gain.gain.setValueAtTime(0.2, now + 1.0);
      gain.gain.linearRampToValueAtTime(0, now + 1.2);
      osc.connect(gain).connect(ctx.destination);
      osc.start(now);
      osc.stop(now + 1.25);
    } catch (e) {
      /* ignore */
    }
  };

  return (
    <>
      <div className={styles.play_wrap}>
        <button className={styles.play} onClick={playTone} type="button">
          🔊 {t('GamesPage.PlayTone')}
        </button>
        <span className={styles.hint}>{t('GamesPage.FreqHint')}</span>
      </div>

      <div className={styles.timer}>{seconds > 0 ? `${seconds}s` : '…'}</div>
      <div className={styles.guess_value}>{guessHz} Hz</div>

      <input
        className={styles.slider}
        type="range"
        min="0"
        max="1000"
        value={pos}
        onChange={(e) => setPos(Number(e.target.value))}
      />
      <div className={styles.scale}>
        <span>{MIN_HZ} Hz</span>
        <span>{MAX_HZ} Hz</span>
      </div>

      <button className={styles.submit} onClick={submit} disabled={submitting}>
        {t('GamesPage.SubmitGuess')}
      </button>
    </>
  );
}

export function Frequency({ match, onSubmit, submitting }) {
  const { t } = useTranslation();
  const total = match.roundsCount;
  const current = match.me.submissionsCount;
  const done = current >= total;

  return (
    <section className={styles.board}>
      <div className={styles.scoreboard}>
        <div className={styles.score_block}>
          <span className={styles.score_name}>{t('GamesPage.You')}</span>
          <span className={styles.score_value}>{match.me.score}</span>
          <span className={styles.score_progress}>{current}/{total}</span>
        </div>
        <div className={styles.round_indicator}>
          {done ? t('GamesPage.Done') : `${t('GamesPage.Round')} ${current + 1}/${total}`}
        </div>
        <div className={styles.score_block}>
          <span className={styles.score_name}>{match.opponent.user?.name || t('GamesPage.Opponent')}</span>
          <span className={styles.score_value}>{match.opponent.finishedAt ? '✓' : '…'}</span>
          <span className={styles.score_progress}>{match.opponent.submissionsCount}/{total}</span>
        </div>
      </div>

      {done ? (
        <div className={styles.waiting}><p>{t('GamesPage.WaitingOpponent')}</p></div>
      ) : (
        <FrequencyRound
          key={current}
          roundIndex={current}
          target={match.rounds[current].prompt.target}
          onSubmit={onSubmit}
          submitting={submitting}
        />
      )}
    </section>
  );
}
FREOF
echo "  wrote Frequency.jsx"

cat > frontend/src/pages/GamesPage/games/Frequency.module.css << 'FREOF'
.board {
  background-color: var(--filling_background-color_global);
  padding: 18px 16px 28px;
}

.scoreboard {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 24px;
}

.score_block {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
  min-width: 90px;
}

.score_name {
  font-size: 13px;
  color: var(--separator_color_global);
  max-width: 110px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.score_value { font-size: 24px; font-weight: 800; color: var(--color_global); }
.score_progress { font-size: 12px; color: var(--separator_color_global); }
.round_indicator { font-weight: 700; color: var(--color_global); }

.play_wrap {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}

.play {
  padding: 14px 30px;
  border: none;
  border-radius: 14px;
  background-color: var(--hashtag_color_global);
  color: #fff;
  font-size: 18px;
  font-weight: 700;
  cursor: pointer;
}

.hint { font-size: 12px; color: var(--separator_color_global); }

.timer {
  text-align: center;
  font-size: 14px;
  color: var(--separator_color_global);
  margin: 14px 0 4px;
}

.guess_value {
  text-align: center;
  font-size: 30px;
  font-weight: 800;
  color: var(--color_global);
  font-variant-numeric: tabular-nums;
  margin-bottom: 14px;
}

.slider {
  display: block;
  width: 100%;
  max-width: 360px;
  margin: 0 auto;
  cursor: pointer;
  accent-color: var(--hashtag_color_global);
}

.scale {
  display: flex;
  justify-content: space-between;
  max-width: 360px;
  margin: 6px auto 0;
  font-size: 12px;
  color: var(--separator_color_global);
}

.submit {
  display: block;
  margin: 22px auto 0;
  padding: 12px 28px;
  border: none;
  border-radius: 12px;
  background-color: var(--hashtag_color_global);
  color: #fff;
  font-size: 16px;
  font-weight: 700;
  cursor: pointer;
}

.submit:disabled { opacity: 0.6; cursor: default; }

.waiting { text-align: center; color: var(--separator_color_global); padding: 30px 0; }
FREOF
echo "  wrote Frequency.module.css"

node <<'NODE'
const fs=require('fs');
function patch(file, edits){ let s=fs.readFileSync(file,'utf8'); for(const [o,n,l] of edits){ const c=s.split(o).length-1; if(c===0){console.log('  - skip: '+l);continue;} s=s.split(o).join(n); console.log('  + '+l+' ('+c+'x)'); } fs.writeFileSync(file,s); }

patch('backend/src/modules/game/engine/index.js', [
[`import { math } from './math.js';`, `import { math } from './math.js';\nimport { frequency } from './frequency.js';`, 'engine: import frequency'],
[`    colorGuess,\n    math\n`, `    colorGuess,\n    math,\n    frequency\n`, 'engine: register frequency'],
]);

patch('frontend/src/pages/GamesPage/GamesPage.jsx', [
[`import { MathSprint } from './games/MathSprint';`, `import { MathSprint } from './games/MathSprint';\nimport { Frequency } from './games/Frequency';`, 'GamesPage: import Frequency'],
[`const BOARDS = { colorGuess: ColorGuess, math: MathSprint };`, `const BOARDS = { colorGuess: ColorGuess, math: MathSprint, frequency: Frequency };`, 'GamesPage: register board'],
[`description: 'Hear a tone, guess the Hz.', available: false`, `description: 'Hear a tone, guess the Hz.', available: true`, 'GamesPage: mark available'],
]);

const add={ en:{PlayTone:"Play tone",FreqHint:"Listen, then slide to the pitch you heard"}, ru:{PlayTone:"Сыграть тон",FreqHint:"Послушайте и подберите высоту"} };
for(const lang of ['en','ru']){ const p='frontend/public/locales/'+lang+'/translation.json'; const j=JSON.parse(fs.readFileSync(p,'utf8')); j.GamesPage={...(j.GamesPage||{}),...add[lang]}; fs.writeFileSync(p, JSON.stringify(j,null,2)+'\n'); console.log('  + locale '+lang); }
console.log('\nDone. Frequency added.');
NODE

echo "Verifying..."
node --check backend/src/modules/game/engine/frequency.js && echo "  OK frequency.js"
node --check backend/src/modules/game/engine/index.js && echo "  OK index.js"
