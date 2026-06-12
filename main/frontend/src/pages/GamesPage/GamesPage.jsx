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
