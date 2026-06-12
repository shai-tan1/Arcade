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
  { key: 'colorGuess', name: 'Color Guess', emoji: '🎨', description: 'A color is shown — guess its RGB. Closest wins.', available: true },
  { key: 'math', name: 'Math Sprint', emoji: '🔢', description: 'Rapid-fire number puzzles.', available: true },
  { key: 'frequency', name: 'Frequency', emoji: '🔊', description: 'Hear a tone, guess the Hz.', available: true },
  { key: 'wordle', name: 'Wordle Duel', emoji: '🟩', description: 'Race to crack the word.', available: false },
  { key: 'sudoku', name: 'Sudoku', emoji: '🧩', description: 'Solve faster than your rival.', available: false },
  { key: 'zip', name: 'Zip', emoji: '➿', description: 'Connect 1→N through every cell.', available: false }
];

const BOARDS = { colorGuess: ColorGuess, math: MathSprint, frequency: Frequency };

const gameName = (key) => GAMES.find((g) => g.key === key)?.name || key;

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
  return (
    <div className={styles.games_page}>
      <div className={styles.title}><h1>{t('GamesPage.Games')}</h1></div>
      <div className={styles.grid}>
        {GAMES.map((game) => (
          game.available ? (
            <Link key={game.key} to={`/games/${game.key}`} className={styles.card}>
              <span className={styles.card_emoji}>{game.emoji}</span>
              <span className={styles.card_name}>{game.name}</span>
              <span className={styles.card_desc}>{game.description}</span>
            </Link>
          ) : (
            <div key={game.key} className={`${styles.card} ${styles.card_soon}`}>
              <span className={styles.card_emoji}>{game.emoji}</span>
              <span className={styles.card_name}>{game.name}</span>
              <span className={styles.card_badge}>{t('GamesPage.Soon')}</span>
            </div>
          )
        ))}
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

  const myRating = ratingsQuery.data?.find((r) => r.gameType === gameType)?.rating ?? 1000;
  const incoming = (challengesQuery.data || []).filter((c) => c.gameType === gameType);
  const friends = friendsQuery.data || [];

  return (
    <div className={styles.games_page}>
      <div className={styles.title}>
        <Link to="/games" className={styles.back_link}>←</Link>
        <h1>{gameName(gameType)}</h1>
      </div>

      <section className={styles.section}>
        <div className={styles.rating_row}>
          <span className={styles.rating_label}>{t('GamesPage.YourRating')}</span>
          <span className={styles.rating_value}>{myRating}</span>
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
      </section>

      {incoming.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.section_title}>{t('GamesPage.Challenges')}</h2>
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

      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('GamesPage.ChallengeFriend')}</h2>
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

      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('GamesPage.Leaderboard')}</h2>
        {leaderboardQuery.data?.length === 0 && <p className={styles.empty}>{t('GamesPage.NoRanking')}</p>}
        <ol className={styles.leaderboard}>
          {leaderboardQuery.data?.map((entry, i) => (
            <li key={entry.user?._id || i} className={styles.lb_row}>
              <span className={styles.lb_rank}>{i + 1}</span>
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
      <div className={styles.games_page}>
        <div className={styles.title}><Link to="/games" className={styles.back_link}>←</Link><h1>{t('GamesPage.Games')}</h1></div>
        <p className={styles.empty}>{t('GamesPage.MatchError')}</p>
      </div>
    );
  }

  const match = matchQuery.data;
  const Board = BOARDS[match.gameType];

  if (match.status === 'pending') {
    return (
      <div className={styles.games_page}>
        <div className={styles.title}><Link to={`/games/${match.gameType}`} className={styles.back_link}>←</Link><h1>{gameName(match.gameType)}</h1></div>
        <section className={styles.section}>
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
      <div className={styles.games_page}>
        <div className={styles.title}><Link to={`/games/${match.gameType}`} className={styles.back_link}>←</Link><h1>{gameName(match.gameType)}</h1></div>
        <section className={`${styles.section} ${styles.result}`}>
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
    <div className={styles.games_page}>
      <div className={styles.title}>
        <h1>{gameName(match.gameType)}</h1>
        <button className={styles.forfeit} onClick={() => forfeitMutation.mutate()}>{t('GamesPage.Forfeit')}</button>
      </div>
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
