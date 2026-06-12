// frontend/src/pages/GamesPage/games/MathSprint.jsx

import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';

import styles from './MathSprint.module.css';

const ROUND_SECONDS = 12;

function MathRound({ text, roundIndex, onSubmit, submitting }) {
  const { t } = useTranslation();
  const [val, setVal] = useState('');
  const [seconds, setSeconds] = useState(ROUND_SECONDS);
  const submittedRef = useRef(false);
  const inputRef = useRef(null);

  useEffect(() => {
    inputRef.current?.focus();
    const id = setInterval(() => setSeconds((s) => s - 1), 1000);
    return () => clearInterval(id);
  }, [roundIndex]);

  const submit = () => {
    if (submittedRef.current) return;
    submittedRef.current = true;
    const n = parseInt(val, 10);
    onSubmit(roundIndex, Number.isFinite(n) ? n : 0);
  };

  useEffect(() => {
    if (seconds <= 0) submit();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seconds]);

  return (
    <>
      <div className={styles.timer}>{seconds > 0 ? `${seconds}s` : '…'}</div>
      <div className={styles.question}>{text} = ?</div>
      <input
        ref={inputRef}
        className={styles.input}
        type="number"
        inputMode="numeric"
        value={val}
        onChange={(e) => setVal(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') submit(); }}
        placeholder="?"
      />
      <button className={styles.submit} onClick={submit} disabled={submitting}>
        {t('GamesPage.Submit')}
      </button>
    </>
  );
}

export function MathSprint({ match, onSubmit, submitting }) {
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
        <MathRound
          key={current}
          roundIndex={current}
          text={match.rounds[current].prompt.text}
          onSubmit={onSubmit}
          submitting={submitting}
        />
      )}
    </section>
  );
}
