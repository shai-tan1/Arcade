// frontend/src/pages/GamesPage/games/ColorGuess.jsx

import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';

import styles from './ColorGuess.module.css';

const ROUND_SECONDS = 20;

function Slider({ label, value, onChange, channel }) {
  return (
    <div className={styles.slider_row}>
      <span className={`${styles.slider_label} ${styles[channel]}`}>{label}</span>
      <input
        className={`${styles.slider} ${styles[`slider_${channel}`]}`}
        type="range"
        min="0"
        max="255"
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      <span className={styles.slider_value}>{value}</span>
    </div>
  );
}

// One round: shows the target swatch, lets the player guess, auto-submits on timeout.
function ColorRound({ target, roundIndex, onSubmit, submitting }) {
  const { t } = useTranslation();
  const [guess, setGuess] = useState({ r: 128, g: 128, b: 128 });
  const [seconds, setSeconds] = useState(ROUND_SECONDS);

  useEffect(() => {
    const id = setInterval(() => setSeconds((s) => s - 1), 1000);
    return () => clearInterval(id);
  }, [roundIndex]);

  useEffect(() => {
    if (seconds <= 0) onSubmit(roundIndex, guess);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seconds]);

  const targetCss = `rgb(${target.r}, ${target.g}, ${target.b})`;
  const guessCss = `rgb(${guess.r}, ${guess.g}, ${guess.b})`;

  return (
    <>
      <div className={styles.swatches}>
        <div className={styles.swatch_wrap}>
          <div className={styles.swatch} style={{ backgroundColor: targetCss }} />
          <span className={styles.swatch_label}>{t('GamesPage.ColorShown')}</span>
        </div>
        <div className={styles.swatch_wrap}>
          <div className={styles.swatch} style={{ backgroundColor: guessCss }} />
          <span className={styles.swatch_label}>{t('GamesPage.ColorYourGuess')}</span>
        </div>
      </div>

      <div className={styles.timer}>{seconds > 0 ? `${seconds}s` : '…'}</div>

      <div className={styles.sliders}>
        <Slider label="R" channel="r" value={guess.r} onChange={(v) => setGuess({ ...guess, r: v })} />
        <Slider label="G" channel="g" value={guess.g} onChange={(v) => setGuess({ ...guess, g: v })} />
        <Slider label="B" channel="b" value={guess.b} onChange={(v) => setGuess({ ...guess, b: v })} />
      </div>

      <button
        className={styles.submit}
        onClick={() => onSubmit(roundIndex, guess)}
        disabled={submitting}
      >
        {t('GamesPage.SubmitGuess')}
      </button>
    </>
  );
}

export function ColorGuess({ match, onSubmit, submitting }) {
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
        <div className={styles.waiting}>
          <p>{t('GamesPage.WaitingOpponent')}</p>
        </div>
      ) : (
        <ColorRound
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
