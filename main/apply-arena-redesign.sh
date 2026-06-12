#!/usr/bin/env bash
# Matiks-style Games arena: stat chips + square duel tiles (corner rating badges) + feature cards,
# plus the per-game rank-card lobby. Only the Games page changes; all handlers/queries unchanged.
# Best applied AFTER apply-theme-arena.sh. Run from the repo "main/" directory.
set -e
if [ ! -d frontend/src ]; then echo "ERROR: run from your repo's main/ directory"; exit 1; fi
if [ ! -f frontend/src/pages/GamesPage/GamesPage.jsx ]; then echo "ERROR: games feature missing (run apply-games.sh first)"; exit 1; fi

cat > frontend/src/pages/GamesPage/GamesPage.jsx << 'JSXEOF'
// frontend/src/pages/GamesPage/GamesPage.jsx

import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon } from '../../shared/ui';
import { ColorGuess } from './games/ColorGuess';
import { MathSprint } from './games/MathSprint';
import { Frequency } from './games/Frequency';

import styles from './GamesPage.module.css';

export const GAMES = [
  { key: 'colorGuess', name: 'Color Guess', emoji: '🎨', description: 'A color is shown — guess its RGB. Closest wins.', sub: 'Guess the RGB', available: true, tint: '#e0567f' },
  { key: 'math', name: 'Math Sprint', emoji: '🔢', description: 'Rapid-fire number puzzles.', sub: 'Rapid-fire math', available: true, tint: '#3b82f6' },
  { key: 'frequency', name: 'Frequency', emoji: '🔊', description: 'Hear a tone, guess the Hz.', sub: 'Hear the pitch', available: true, tint: '#2dd4bf' },
  { key: 'wordle', name: 'Wordle Duel', emoji: '🟩', description: 'Race to crack the word.', sub: 'Crack the word', available: false, tint: '#84cc16' },
  { key: 'sudoku', name: 'Sudoku', emoji: '🧩', description: 'Solve faster than your rival.', sub: 'Solve faster', available: false, tint: '#a78bfa' },
  { key: 'zip', name: 'Zip', emoji: '➿', description: 'Connect 1→N through every cell.', sub: 'Connect the path', available: false, tint: '#f59e0b' }
];

const BOARDS = { colorGuess: ColorGuess, math: MathSprint, frequency: Frequency };

const gameMeta = (key) => GAMES.find((g) => g.key === key) || {};
const gameName = (key) => gameMeta(key).name || key;

function Avatar({ user, size = 38 }) {
  const style = { width: size, height: size };
  if (user?.avatarUri) {
    return <img className={styles.avatar} style={style} src={(/^https?:\/\//.test(user.avatarUri) ? user.avatarUri : API_BASE_URL + user.avatarUri)} alt={user.name} />;
  }
  return <span className={`${styles.avatar} ${styles.avatar_empty}`} style={style}><NoAvatarIcon /></span>;
}

/* ----------------------------- Picker ----------------------------- */
function GamePicker() {
  const { t } = useTranslation();
  const ratingsQuery = useQuery({
    queryKey: ['games', 'ratings'],
    queryFn: () => httpClient.get('/games/ratings'),
    retry: false
  });
  const ratings = ratingsQuery.data || [];
  const ratingFor = (key) => ratings.find((r) => r.gameType === key);
  const totalPlayed = ratings.reduce((s, r) => s + (r.played || 0), 0);
  const totalWins = ratings.reduce((s, r) => s + (r.won || 0), 0);
  const topRating = ratings.length ? Math.max(...ratings.map((r) => r.rating || 0)) : 0;
  const firstAvailable = GAMES.find((g) => g.available)?.key || 'colorGuess';

  return (
    <div className={styles.arena}>
      <header className={styles.hero}>
        <h1 className={styles.hero_title}>{t('GamesPage.Arena')}</h1>
        <p className={styles.hero_sub}>{t('GamesPage.ArenaSubtitle')}</p>
      </header>

      <div className={styles.stats}>
        <div className={styles.stat}><span className={styles.stat_v}>{totalPlayed}</span><span className={styles.stat_l}>{t('GamesPage.GamesPlayed')}</span></div>
        <div className={styles.stat}><span className={styles.stat_v}>{totalWins}</span><span className={styles.stat_l}>{t('GamesPage.WinsStat')}</span></div>
        <div className={styles.stat}><span className={styles.stat_v}>{topRating || '—'}</span><span className={styles.stat_l}>{t('GamesPage.TopRating')}</span></div>
      </div>

      <div className={styles.sechead}><h2>{t('GamesPage.Duels')}</h2></div>
      <div className={styles.duels}>
        {GAMES.map((game) => {
          const r = ratingFor(game.key);
          const inner = (
            <>
              {game.available
                ? (r ? <span className={styles.badge}>{r.rating}</span> : <span className={styles.badge_play}>▶</span>)
                : <span className={styles.soon}>{t('GamesPage.Soon')}</span>}
              <span className={styles.chip} style={{ '--tint': game.tint }}>{game.emoji}</span>
              <span className={styles.nm}>{game.name}</span>
              <span className={styles.sub}>{game.sub}</span>
            </>
          );
          return game.available ? (
            <Link key={game.key} to={`/games/${game.key}`} className={styles.duel}>{inner}</Link>
          ) : (
            <div key={game.key} className={`${styles.duel} ${styles.locked}`}>{inner}</div>
          );
        })}
      </div>

      <div className={styles.sechead}><h2>{t('GamesPage.PlayNow')}</h2></div>
      <div className={styles.features}>
        <Link to={`/games/${firstAvailable}`} className={styles.feat}>
          <span className={styles.feat_glow} />
          <span className={styles.feat_tag}>{t('GamesPage.Ranked')}</span>
          <h3 className={styles.feat_h}>{t('GamesPage.FindMatch')}</h3>
          <p className={styles.feat_p}>{t('GamesPage.FindMatchSub')}</p>
        </Link>
        <Link to={`/games/${firstAvailable}`} className={styles.feat}>
          <span className={styles.feat_glow} />
          <span className={styles.feat_tag}>{t('GamesPage.Friendly')}</span>
          <h3 className={styles.feat_h}>{t('GamesPage.ChallengeFriend')}</h3>
          <p className={styles.feat_p}>{t('GamesPage.ChallengeFriendSub')}</p>
        </Link>
      </div>
    </div>
  );
}

/* ----------------------------- Lobby ----------------------------- */
function GameLobby({ gameType }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [searching, setSearching] = useState(false);

  const activeQuery = useQuery({
    queryKey: ['games', 'active'],
    queryFn: () => httpClient.get('/games/active'),
    retry: false
  });
  const ratingsQuery = useQuery({
    queryKey: ['games', 'ratings'],
    queryFn: () => httpClient.get('/games/ratings'),
    retry: false
  });
  const leaderboardQuery = useQuery({
    queryKey: ['games', gameType, 'leaderboard'],
    queryFn: () => httpClient.get(`/games/${gameType}/leaderboard`),
    retry: false
  });
  const friendsQuery = useQuery({
    queryKey: ['friends', 'list'],
    queryFn: () => httpClient.get('/friends'),
    retry: false
  });
  const challengesQuery = useQuery({
    queryKey: ['games', 'challenges'],
    queryFn: () => httpClient.get('/games/challenges'),
    retry: false
  });

  // Jump into a match as soon as one exists for me.
  useEffect(() => {
    if (activeQuery.data?.matchId) {
      navigate(`/games/match/${activeQuery.data.matchId}`);
    }
  }, [activeQuery.data, navigate]);

  const joinMutation = useMutation({
    mutationFn: () => httpClient.post('/games/queue', { gameType }),
    onSuccess: (data) => {
      if (data?.status === 'matched' && data.matchId) {
        navigate(`/games/match/${data.matchId}`);
      } else {
        setSearching(true);
      }
    }
  });
  const cancelMutation = useMutation({
    mutationFn: () => httpClient.post('/games/queue/leave', { gameType }),
    onSuccess: () => setSearching(false)
  });
  const challengeMutation = useMutation({
    mutationFn: (friendUserId) => httpClient.post('/games/challenge', { gameType, friendUserId })
  });
  const acceptMutation = useMutation({
    mutationFn: (matchId) => httpClient.post(`/games/match/${matchId}/accept`),
    onSuccess: (data, matchId) => navigate(`/games/match/${matchId}`)
  });
  const declineMutation = useMutation({
    mutationFn: (matchId) => httpClient.post(`/games/match/${matchId}/decline`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['games', 'challenges'] })
  });

  const meta = gameMeta(gameType);
  const myRatingDoc = ratingsQuery.data?.find((r) => r.gameType === gameType);
  const myRating = myRatingDoc?.rating ?? 1000;
  const wins = myRatingDoc?.won ?? 0;
  const losses = myRatingDoc?.lost ?? 0;
  const barPct = Math.max(4, Math.min(100, Math.round(((myRating - 800) / (2000 - 800)) * 100)));
  const incoming = (challengesQuery.data || []).filter((c) => c.gameType === gameType);
  const friends = friendsQuery.data || [];

  return (
    <div className={styles.arena}>
      <header className={styles.lobby_head}>
        <Link to="/games" className={styles.back}>←</Link>
        <h1 className={styles.lobby_title}>{meta.name || gameName(gameType)}</h1>
      </header>

      <div className={styles.rank_card}>
        <span className={styles.rank_icon} style={{ '--tint': meta.tint }}>{meta.emoji}</span>
        <div className={styles.rank_body}>
          <span className={styles.rank_label}>{t('GamesPage.RankRating')}</span>
          <span className={styles.rank_value}>{myRating}</span>
          <div className={styles.rank_bar}><span className={styles.rank_bar_fill} style={{ width: `${barPct}%` }} /></div>
          <span className={styles.rank_record}>{wins}{t('GamesPage.WinShort')} · {losses}{t('GamesPage.LossShort')}</span>
        </div>
      </div>

      {searching ? (
        <div className={styles.searching}>
          <div className={styles.loader}><Loader /></div>
          <span>{t('GamesPage.Searching')}</span>
          <button className={styles.btn_muted} onClick={() => cancelMutation.mutate()}>{t('GamesPage.Cancel')}</button>
        </div>
      ) : (
        <button className={styles.btn_primary_lg} onClick={() => joinMutation.mutate()} disabled={joinMutation.isPending}>
          {t('GamesPage.FindMatch')}
        </button>
      )}

      {incoming.length > 0 && (
        <section className={styles.card}>
          <h2 className={styles.card_title}>{t('GamesPage.Challenges')}</h2>
          {incoming.map((c) => (
            <div key={c.matchId} className={styles.row}>
              <div className={styles.row_user}><Avatar user={c.user} /><span className={styles.row_name}>{c.user?.name}</span></div>
              <div className={styles.row_actions}>
                <button className={styles.btn_primary} onClick={() => acceptMutation.mutate(c.matchId)}>{t('GamesPage.Accept')}</button>
                <button className={styles.btn_muted} onClick={() => declineMutation.mutate(c.matchId)}>{t('GamesPage.Decline')}</button>
              </div>
            </div>
          ))}
        </section>
      )}

      <section className={styles.card}>
        <h2 className={styles.card_title}>{t('GamesPage.ChallengeFriend')}</h2>
        {friends.length === 0 && <p className={styles.empty}>{t('GamesPage.NoFriends')}</p>}
        {friends.map((f) => (
          <div key={f.friendshipId} className={styles.row}>
            <div className={styles.row_user}><Avatar user={f.user} /><span className={styles.row_name}>{f.user?.name}</span></div>
            <button
              className={styles.btn_secondary}
              onClick={() => challengeMutation.mutate(f.user._id)}
              disabled={challengeMutation.isPending}
            >
              {challengeMutation.isSuccess && challengeMutation.variables === f.user._id ? t('GamesPage.Sent') : t('GamesPage.Challenge')}
            </button>
          </div>
        ))}
      </section>

      <section className={styles.card}>
        <h2 className={styles.card_title}>{t('GamesPage.Leaderboard')}</h2>
        {leaderboardQuery.data?.length === 0 && <p className={styles.empty}>{t('GamesPage.NoRanking')}</p>}
        <ol className={styles.leaderboard}>
          {leaderboardQuery.data?.map((entry, i) => (
            <li key={entry.user?._id || i} className={styles.lb_row}>
              <span className={`${styles.lb_rank} ${styles['lb_rank_' + (i + 1)] || ''}`}>{i + 1}</span>
              <Link to={`/${entry.user?.customId}`} className={styles.row_user}>
                <Avatar user={entry.user} size={32} />
                <span className={styles.row_name}>{entry.user?.name}</span>
              </Link>
              <span className={styles.lb_rating}>{entry.rating}</span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}

/* ----------------------------- Match ----------------------------- */
function GameMatch({ matchId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const matchQuery = useQuery({
    queryKey: ['games', 'match', matchId],
    queryFn: () => httpClient.get(`/games/match/${matchId}`),
    retry: false
  });

  const submitMutation = useMutation({
    mutationFn: ({ roundIndex, answer }) => httpClient.post(`/games/match/${matchId}/submit`, { roundIndex, answer }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['games', 'match', matchId] })
  });
  const forfeitMutation = useMutation({
    mutationFn: () => httpClient.post(`/games/match/${matchId}/forfeit`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['games', 'match', matchId] })
  });
  const rematchMutation = useMutation({
    mutationFn: (friendUserId) => httpClient.post('/games/challenge', { gameType: matchQuery.data.gameType, friendUserId }),
    onSuccess: () => navigate(`/games/${matchQuery.data.gameType}`)
  });

  if (matchQuery.isPending) {
    return <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>;
  }
  if (matchQuery.isError) {
    return (
      <div className={styles.arena}>
        <header className={styles.lobby_head}><Link to="/games" className={styles.back}>←</Link><h1 className={styles.lobby_title}>{t('GamesPage.Games')}</h1></header>
        <p className={styles.empty}>{t('GamesPage.MatchError')}</p>
      </div>
    );
  }

  const match = matchQuery.data;
  const Board = BOARDS[match.gameType];

  if (match.status === 'pending') {
    return (
      <div className={styles.arena}>
        <header className={styles.lobby_head}><Link to={`/games/${match.gameType}`} className={styles.back}>←</Link><h1 className={styles.lobby_title}>{gameName(match.gameType)}</h1></header>
        <section className={styles.card}>
          <p className={styles.waiting}>{t('GamesPage.WaitingAccept')}</p>
        </section>
      </div>
    );
  }

  if (match.status === 'finished') {
    const delta = (match.me.ratingAfter != null && match.me.ratingBefore != null)
      ? match.me.ratingAfter - match.me.ratingBefore : null;
    const outcome = match.isWinner === true ? 'win' : match.isWinner === false ? 'loss' : 'draw';
    return (
      <div className={styles.arena}>
        <header className={styles.lobby_head}><Link to={`/games/${match.gameType}`} className={styles.back}>←</Link><h1 className={styles.lobby_title}>{gameName(match.gameType)}</h1></header>
        <section className={`${styles.card} ${styles.result}`}>
          <span className={`${styles.result_badge} ${styles[`result_${outcome}`]}`}>{t(`GamesPage.${outcome === 'win' ? 'Won' : outcome === 'loss' ? 'Lost' : 'Draw'}`)}</span>
          <div className={styles.scoreline}>
            <span>{t('GamesPage.You')}: <b>{match.me.score}</b></span>
            <span>{match.opponent.user?.name}: <b>{match.opponent.score}</b></span>
          </div>
          {delta != null && (
            <span className={styles.elo_delta}>
              {t('GamesPage.Rating')}: {match.me.ratingAfter} ({delta >= 0 ? `+${delta}` : delta})
            </span>
          )}
          <div className={styles.result_actions}>
            {match.opponent.user?._id && (
              <button className={styles.btn_primary} onClick={() => rematchMutation.mutate(match.opponent.user._id)}>
                {t('GamesPage.Rematch')}
              </button>
            )}
            <Link className={styles.btn_secondary} to={`/games/${match.gameType}`}>{t('GamesPage.BackToLobby')}</Link>
          </div>
        </section>
      </div>
    );
  }

  // active
  return (
    <div className={styles.arena}>
      <header className={styles.lobby_head}>
        <h1 className={styles.lobby_title}>{gameName(match.gameType)}</h1>
        <button className={styles.forfeit} onClick={() => forfeitMutation.mutate()}>{t('GamesPage.Forfeit')}</button>
      </header>
      {Board ? (
        <Board match={match} onSubmit={(roundIndex, answer) => submitMutation.mutate({ roundIndex, answer })} submitting={submitMutation.isPending} />
      ) : (
        <p className={styles.empty}>{t('GamesPage.Soon')}</p>
      )}
    </div>
  );
}

/* ----------------------------- Page ----------------------------- */
export function GamesPage() {
  const { gameType, matchId } = useParams();
  if (matchId) return <GameMatch matchId={matchId} />;
  if (gameType) return <GameLobby gameType={gameType} />;
  return <GamePicker />;
}
JSXEOF
echo "  + GamesPage.jsx"

cat > frontend/src/pages/GamesPage/GamesPage.module.css << 'CSSEOF'
.arena {
  margin-bottom: var(--content_margin_bottom_global);
  padding: 4px 14px 0;
}

/* ---------- hero (picker) ---------- */
.hero {
  padding: 14px 4px 18px;
}
.hero_title {
  font-family: Arial, Helvetica, sans-serif;
  font-size: 30px;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: var(--color_global);
}
.hero_sub {
  margin-top: 6px;
  font-size: 14px;
  color: var(--separator_color_global);
}

/* ---------- stat chips ---------- */
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin: 20px 0; }
.stat { background-color: var(--filling_background-color_global); border: var(--border_global); border-radius: 14px; padding: 14px 16px; }
.stat_v { display: block; font-size: 22px; font-weight: 800; color: var(--color_global); }
.stat_l { display: block; font-size: 12px; color: var(--separator_color_global); text-transform: uppercase; letter-spacing: 0.05em; margin-top: 2px; }

/* ---------- section heading ---------- */
.sechead { margin: 24px 0 14px; }
.sechead h2 { font-size: 13px; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; color: var(--separator_color_global); }

/* ---------- duel tiles ---------- */
.duels { display: grid; grid-template-columns: repeat(auto-fill, minmax(135px, 1fr)); gap: 14px; }
.duel {
  position: relative;
  aspect-ratio: 1 / 1.06;
  display: flex;
  flex-direction: column;
  padding: 16px;
  border-radius: 18px;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
  text-decoration: none;
  color: var(--color_global);
  transition: transform 140ms ease, border-color 140ms ease, background-color 140ms ease;
}
a.duel:hover {
  transform: translateY(-3px);
  background-color: var(--item_hover_global);
  border-color: color-mix(in srgb, var(--hashtag_color_global) 50%, transparent);
}
.chip {
  width: 48px;
  height: 48px;
  border-radius: 14px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 25px;
  background-color: color-mix(in srgb, var(--tint) 20%, transparent);
  border: 1px solid color-mix(in srgb, var(--tint) 38%, transparent);
}
.nm { margin-top: auto; font-size: 15px; font-weight: 700; color: var(--color_global); }
.sub { font-size: 12px; color: var(--separator_color_global); margin-top: 2px; }
.badge { position: absolute; top: 12px; right: 12px; background-color: var(--hashtag_color_global); color: var(--on_accent_global); font-weight: 800; font-size: 12px; padding: 3px 9px; border-radius: 8px; }
.badge_play { position: absolute; top: 12px; right: 14px; color: var(--hashtag_color_global); font-size: 13px; }
.soon { position: absolute; top: 12px; right: 12px; font-size: 10px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--separator_color_global); border: var(--border_global); border-radius: 7px; padding: 3px 7px; }
.locked { opacity: 0.5; }

/* ---------- feature cards ---------- */
.features { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.feat {
  position: relative;
  overflow: hidden;
  min-height: 128px;
  padding: 22px;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
  border-radius: 18px;
  text-decoration: none;
  color: var(--color_global);
  transition: border-color 140ms ease;
}
.feat:hover { border-color: color-mix(in srgb, var(--hashtag_color_global) 50%, transparent); }
.feat_glow { position: absolute; right: -30px; top: -30px; width: 120px; height: 120px; border-radius: 50%; background: radial-gradient(circle, color-mix(in srgb, var(--hashtag_color_global) 16%, transparent), transparent 70%); }
.feat_tag { position: absolute; top: 18px; left: 22px; font-size: 11px; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; color: var(--hashtag_color_global); }
.feat_h { font-size: 22px; font-weight: 800; letter-spacing: -0.01em; line-height: 1.05; color: var(--color_global); }
.feat_p { font-size: 13px; color: var(--separator_color_global); margin-top: 6px; }

/* ---------- lobby header ---------- */
.lobby_head {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 14px 0 18px;
}
.lobby_title {
  font-family: Arial, Helvetica, sans-serif;
  font-size: 24px;
  font-weight: 800;
  color: var(--color_global);
}
.back {
  position: absolute;
  left: 2px;
  font-size: 22px;
  text-decoration: none;
  color: var(--color_global);
}
.forfeit {
  position: absolute;
  right: 2px;
  background: transparent;
  border: var(--border_global);
  color: var(--separator_color_global);
  border-radius: 8px;
  padding: 6px 12px;
  cursor: pointer;
  font-size: 13px;
}

/* ---------- rank card ---------- */
.rank_card {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 18px;
  border-radius: 18px;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
}
.rank_icon {
  width: 60px;
  height: 60px;
  flex-shrink: 0;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 32px;
  background-color: color-mix(in srgb, var(--tint) 20%, transparent);
  border: 1px solid color-mix(in srgb, var(--tint) 38%, transparent);
}
.rank_body { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.rank_label {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--separator_color_global);
}
.rank_value { font-size: 30px; font-weight: 800; color: var(--color_global); line-height: 1.1; }
.rank_bar {
  height: 8px;
  border-radius: 999px;
  background-color: var(--item_hover_global);
  overflow: hidden;
  margin: 9px 0 7px;
}
.rank_bar_fill { display: block; height: 100%; border-radius: 999px; background-color: var(--hashtag_color_global); }
.rank_record { font-size: 12px; color: var(--separator_color_global); }

/* ---------- buttons ---------- */
.btn_primary_lg {
  width: 100%;
  margin-top: 14px;
  padding: 15px;
  border: none;
  border-radius: 14px;
  background-color: var(--hashtag_color_global);
  color: var(--on_accent_global);
  font-size: 17px;
  font-weight: 800;
  cursor: pointer;
  transition: var(--transition_background-color_hover_global);
}
.btn_primary_lg:hover { background-color: var(--hashtag_color_hover_global); }
.btn_primary_lg:disabled { opacity: 0.6; cursor: default; }

.btn_primary, .btn_secondary, .btn_muted {
  padding: 8px 16px;
  border-radius: 10px;
  border: none;
  cursor: pointer;
  font-size: 14px;
  font-weight: 600;
  text-decoration: none;
  white-space: nowrap;
}
.btn_primary { background-color: var(--hashtag_color_global); color: var(--on_accent_global); }
.btn_secondary { background-color: var(--item_hover_global); color: var(--color_global); }
.btn_muted { background-color: transparent; border: var(--border_global); color: var(--separator_color_global); }
.btn_primary:disabled, .btn_secondary:disabled, .btn_muted:disabled { opacity: 0.55; cursor: default; }

.searching {
  display: flex;
  align-items: center;
  gap: 14px;
  justify-content: center;
  margin-top: 14px;
  padding: 16px;
  border-radius: 14px;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
  color: var(--separator_color_global);
}

/* ---------- section cards ---------- */
.card {
  margin-top: 14px;
  padding: 16px 18px;
  border-radius: 16px;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
}
.card_title {
  font-size: 12px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--separator_color_global);
  margin-bottom: 12px;
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 9px 0;
  border-bottom: var(--border_global);
}
.row:last-child { border-bottom: none; }
.row_user { display: flex; align-items: center; gap: 10px; text-decoration: none; color: var(--color_global); min-width: 0; }
.row_name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row_actions { display: flex; gap: 8px; flex-shrink: 0; }

.empty { color: var(--separator_color_global); padding: 6px 0; }

/* ---------- avatars ---------- */
.avatar { border-radius: 50%; object-fit: cover; display: block; flex-shrink: 0; }
.avatar_empty { display: flex; align-items: center; justify-content: center; background-color: var(--item_hover_global); }
.avatar_empty svg { width: 60%; height: 60%; fill: var(--fill_no_avatar_global); }

/* ---------- leaderboard ---------- */
.leaderboard { list-style: none; }
.lb_row { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-bottom: var(--border_global); }
.lb_row:last-child { border-bottom: none; }
.lb_rank { width: 24px; text-align: center; font-weight: 800; color: var(--separator_color_global); }
.lb_rank_1 { color: #f2c33d; }
.lb_rank_2 { color: #c7ccd1; }
.lb_rank_3 { color: #d08a52; }
.lb_rating { margin-left: auto; font-weight: 800; color: var(--color_global); }

/* ---------- match result / shared ---------- */
.center_loader { height: 280px; display: flex; align-items: center; justify-content: center; }
.loader { height: 21px; width: 21px; }

.waiting { text-align: center; color: var(--separator_color_global); padding: 24px 0; }
.result { display: flex; flex-direction: column; align-items: center; gap: 14px; padding: 28px 16px; text-align: center; }
.result_badge { font-size: 26px; font-weight: 800; padding: 6px 22px; border-radius: 12px; }
.result_win { color: var(--on_accent_global); background-color: var(--hashtag_color_global); }
.result_loss { color: #fff; background-color: #e24b4a; }
.result_draw { color: var(--color_global); background-color: var(--item_hover_global); }
.scoreline { display: flex; gap: 24px; font-size: 17px; }
.elo_delta { color: var(--separator_color_global); }
.result_actions { display: flex; gap: 10px; margin-top: 6px; }
CSSEOF
echo "  + GamesPage.module.css"

node <<'NODE'
const fs=require('fs');
const add={
  en:{Arena:"Arena",ArenaSubtitle:"Duel a friend or get matched. Win to climb your rating.",Play:"Play",RankRating:"Rank rating",WinShort:"W",LossShort:"L",Duels:"Duels",PlayNow:"Play now",GamesPlayed:"Games played",TopRating:"Top rating",WinsStat:"Wins",Ranked:"Ranked",Friendly:"Friendly",FindMatchSub:"Get paired at your level.",ChallengeFriendSub:"Pick a friend, pick a game."},
  ru:{Arena:"Арена",ArenaSubtitle:"Вызовите друга или найдите соперника — побеждайте и растите в рейтинге.",Play:"Играть",RankRating:"Рейтинг",WinShort:"W",LossShort:"L",Duels:"Дуэли",PlayNow:"Играть сейчас",GamesPlayed:"Сыграно игр",TopRating:"Лучший рейтинг",WinsStat:"Победы",Ranked:"Рейтинговый",Friendly:"Дружеский",FindMatchSub:"Подбор соперника по уровню.",ChallengeFriendSub:"Выберите друга и игру."}
};
for(const lang of ['en','ru']){const p='frontend/public/locales/'+lang+'/translation.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.GamesPage={...(j.GamesPage||{}),...add[lang]};fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n');console.log('  + locale '+lang);}
console.log('\nDone. Arena redesign applied.');
NODE
