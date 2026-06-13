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
