#!/usr/bin/env bash
# Adds the Math Sprint game to crystal-v2.0 (run AFTER apply-games.sh).
# Run from the repo "main/" directory:  bash apply-game-math.sh
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then echo "ERROR: run this from ~/crystal-v2.0/main"; exit 1; fi
if [ ! -f backend/src/modules/game/games.routes.js ]; then echo "ERROR: run apply-games.sh first (games framework missing)"; exit 1; fi

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/math.js" << 'CRYSTAL_EOF_5B7D2C10'
// src/modules/game/engine/math.js
// Rapid-fire arithmetic: products, squares, roots, prime-factor questions.
// Every answer is a single integer, scored right/wrong. Speed breaks ties.

import { mulberry32 } from './prng.js';

const ROUNDS = 10;
const POINTS_PER_CORRECT = 10;
const PRIMES = [2, 3, 5, 7, 11, 13];

function randInt(rng, min, max) {
    return Math.floor(rng() * (max - min + 1)) + min;
}
function pick(rng, arr) {
    return arr[Math.floor(rng() * arr.length)];
}

function makeQuestion(rng) {
    const type = pick(rng, ['product', 'square', 'sqrt', 'largestPrime', 'sumPrime']);

    if (type === 'product') {
        const a = randInt(rng, 2, 19);
        const b = randInt(rng, 2, 19);
        return { text: `${a} × ${b}`, solution: a * b };
    }
    if (type === 'square') {
        const n = randInt(rng, 10, 39);
        return { text: `${n}²`, solution: n * n };
    }
    if (type === 'sqrt') {
        const n = randInt(rng, 4, 30);
        return { text: `√${n * n}`, solution: n };
    }
    if (type === 'largestPrime') {
        const k = randInt(rng, 2, 4);
        let N = 1;
        let maxP = 2;
        for (let i = 0; i < k; i++) {
            const p = pick(rng, PRIMES);
            N *= p;
            if (p > maxP) maxP = p;
        }
        return { text: `Largest prime factor of ${N}`, solution: maxP };
    }
    // sumPrime: sum of prime factors with multiplicity
    const k = randInt(rng, 2, 4);
    let N = 1;
    let sum = 0;
    for (let i = 0; i < k; i++) {
        const p = pick(rng, PRIMES);
        N *= p;
        sum += p;
    }
    return { text: `Sum of prime factors of ${N}`, solution: sum };
}

export const math = {
    key: 'math',
    rounds: ROUNDS,

    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const q = makeQuestion(rng);
            rounds.push({ prompt: { type: 'math', text: q.text }, solution: q.solution });
        }
        return rounds;
    },

    score(solution, answer) {
        const a = typeof answer === 'number' ? answer : parseInt(answer, 10);
        return Number.isFinite(a) && a === solution ? POINTS_PER_CORRECT : 0;
    }
};
CRYSTAL_EOF_5B7D2C10
echo "  wrote backend/src/modules/game/engine/math.js"

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/index.js" << 'CRYSTAL_EOF_5B7D2C10'
// src/modules/game/engine/index.js
// Registry of playable games. Add new games here as they are implemented.

import { colorGuess } from './colorGuess.js';
import { math } from './math.js';

export const GAME_ENGINES = {
    colorGuess,
    math
};

export function getEngine(gameType) {
    return GAME_ENGINES[gameType] || null;
}
CRYSTAL_EOF_5B7D2C10
echo "  wrote backend/src/modules/game/engine/index.js"

mkdir -p "backend/src/modules/game"
cat > "backend/src/modules/game/game.controller.js" << 'CRYSTAL_EOF_5B7D2C10'
// src/modules/game/game.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';
import { emitToUsers } from '../../core/engine/web/websocket.js';
import { getEngine } from './engine/index.js';
import { makeSeed } from './engine/prng.js';
import { newRating } from './engine/elo.js';

const matches = () => getDB().collection('gameMatches');
const ratings = () => getDB().collection('gameRatings');
const queue = () => getDB().collection('gameQueue');
const users = () => getDB().collection('users');

const DEFAULT_RATING = 1000;

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1
};

/* ---------------- helpers ---------------- */

// findOneAndDelete returns either the doc (driver v6) or { value } (older).
function unwrap(result) {
    if (!result) return null;
    return result.value !== undefined ? result.value : result;
}

async function getRatingValue(userId, gameType) {
    const r = await ratings().findOne({ userId, gameType });
    return r?.rating ?? DEFAULT_RATING;
}

async function upsertRating(userId, gameType, newRatingValue, outcome) {
    await ratings().updateOne(
        { userId, gameType },
        {
            $set: { userId, gameType, rating: newRatingValue, updatedAt: new Date() },
            $inc: {
                played: 1,
                won: outcome === 1 ? 1 : 0,
                lost: outcome === 0 ? 1 : 0,
                drawn: outcome === 0.5 ? 1 : 0
            }
        },
        { upsert: true }
    );
}

async function createActiveMatch(gameType, mode, userAId, userBId) {
    const engine = getEngine(gameType);
    const seed = makeSeed();
    const rounds = engine.build(seed);
    const doc = {
        gameType,
        mode,
        seed,
        status: 'active',
        rounds,
        players: [
            { userId: userAId, score: 0, finishedAt: null, submissions: [] },
            { userId: userBId, score: 0, finishedAt: null, submissions: [] }
        ],
        winnerId: null,
        createdAt: new Date()
    };
    const result = await matches().insertOne(doc);
    return { _id: result.insertedId, ...doc };
}

async function applyResult(match, winnerId, outcomeA) {
    const set = { status: 'finished', winnerId, finishedAt: new Date() };
    if (match.mode === 'ranked') {
        const a = match.players[0];
        const b = match.players[1];
        const ra = await getRatingValue(a.userId, match.gameType);
        const rb = await getRatingValue(b.userId, match.gameType);
        const na = newRating(ra, rb, outcomeA);
        const nb = newRating(rb, ra, 1 - outcomeA);
        set['players.0.ratingBefore'] = ra;
        set['players.0.ratingAfter'] = na;
        set['players.1.ratingBefore'] = rb;
        set['players.1.ratingAfter'] = nb;
        await upsertRating(a.userId, match.gameType, na, outcomeA);
        await upsertRating(b.userId, match.gameType, nb, 1 - outcomeA);
    }
    await matches().updateOne({ _id: match._id }, { $set: set });
    emitToUsers(match.players.map((p) => p.userId.toString()), {
        type: 'game:over',
        matchId: match._id.toString()
    });
}

async function finalizeIfDone(match) {
    if (match.status !== 'active') return;
    if (!match.players.every((p) => p.finishedAt)) return;
    const [a, b] = match.players;
    let winnerId = null;
    let outcomeA = 0.5;
    if (a.score > b.score) { winnerId = a.userId; outcomeA = 1; }
    else if (b.score > a.score) { winnerId = b.userId; outcomeA = 0; }
    else {
        // tie on score -> the faster finisher wins
        const ta = new Date(a.finishedAt).getTime();
        const tb = new Date(b.finishedAt).getTime();
        if (ta < tb) { winnerId = a.userId; outcomeA = 1; }
        else if (tb < ta) { winnerId = b.userId; outcomeA = 0; }
    }
    await applyResult(match, winnerId, outcomeA);
}

/* ---------------- matchmaking ---------------- */

export const joinQueue = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { gameType, mode = 'ranked' } = req.body;
        if (!getEngine(gameType)) {
            return res.status(400).json({ message: 'Unknown game' });
        }

        // Look for someone already waiting for this game.
        const opponent = unwrap(await queue().findOneAndDelete({ gameType, userId: { $ne: myId } }));

        if (opponent && opponent.userId) {
            await queue().deleteOne({ userId: myId, gameType });
            const match = await createActiveMatch(gameType, mode, opponent.userId, myId);
            emitToUsers([opponent.userId.toString(), myId.toString()], {
                type: 'game:matched',
                matchId: match._id.toString(),
                gameType
            });
            return res.status(200).json({ status: 'matched', matchId: match._id });
        }

        // Otherwise wait in the queue.
        await queue().updateOne(
            { userId: myId, gameType },
            { $set: { userId: myId, gameType, mode, createdAt: new Date() } },
            { upsert: true }
        );
        res.status(200).json({ status: 'queued' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const leaveQueue = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { gameType } = req.body || {};
        await queue().deleteMany({ userId: myId, ...(gameType ? { gameType } : {}) });
        res.status(200).json({ message: 'left' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getActiveMatch = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const match = await matches().findOne(
            { status: 'active', 'players.userId': myId },
            { projection: { _id: 1, gameType: 1 }, sort: { createdAt: -1 } }
        );
        res.status(200).json(match ? { matchId: match._id, gameType: match.gameType } : null);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- challenges ---------------- */

export const createChallenge = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { gameType, friendUserId, mode = 'ranked' } = req.body;
        if (!getEngine(gameType)) {
            return res.status(400).json({ message: 'Unknown game' });
        }
        if (!friendUserId || !ObjectId.isValid(friendUserId)) {
            return res.status(400).json({ message: 'A valid friendUserId is required' });
        }
        const oppId = new ObjectId(friendUserId);
        if (oppId.equals(myId)) {
            return res.status(400).json({ message: 'You cannot challenge yourself' });
        }
        const opp = await users().findOne({ _id: oppId }, { projection: { _id: 1 } });
        if (!opp) {
            return res.status(404).json({ message: 'User not found' });
        }

        const doc = {
            gameType,
            mode,
            status: 'pending',
            challengerId: myId,
            opponentId: oppId,
            players: [
                { userId: myId, score: 0, finishedAt: null, submissions: [] },
                { userId: oppId, score: 0, finishedAt: null, submissions: [] }
            ],
            winnerId: null,
            createdAt: new Date()
        };
        const result = await matches().insertOne(doc);
        emitToUsers([oppId.toString()], { type: 'game:challenge' });
        res.status(201).json({ matchId: result.insertedId, status: 'pending' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getChallenges = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const incoming = await matches().aggregate([
            { $match: { status: 'pending', opponentId: myId } },
            {
                $lookup: {
                    from: 'users',
                    localField: 'challengerId',
                    foreignField: '_id',
                    as: 'user',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: '$user' },
            { $project: { _id: 0, matchId: '$_id', gameType: 1, user: 1, createdAt: 1 } },
            { $sort: { createdAt: -1 } }
        ]).toArray();
        res.status(200).json(incoming);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const acceptChallenge = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { matchId } = req.params;
        if (!ObjectId.isValid(matchId)) {
            return res.status(400).json({ message: 'Invalid match id' });
        }
        const match = await matches().findOne({ _id: new ObjectId(matchId) });
        if (!match) return res.status(404).json({ message: 'Match not found' });
        if (match.status !== 'pending') return res.status(400).json({ message: 'Already handled' });
        if (!match.opponentId?.equals(myId)) return res.status(403).json({ message: 'Not allowed' });

        const engine = getEngine(match.gameType);
        const seed = makeSeed();
        const rounds = engine.build(seed);
        await matches().updateOne(
            { _id: match._id },
            { $set: { status: 'active', seed, rounds } }
        );
        emitToUsers([match.challengerId.toString(), myId.toString()], {
            type: 'game:matched',
            matchId,
            gameType: match.gameType
        });
        res.status(200).json({ status: 'active', matchId });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const declineChallenge = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { matchId } = req.params;
        if (!ObjectId.isValid(matchId)) {
            return res.status(400).json({ message: 'Invalid match id' });
        }
        const match = await matches().findOne({ _id: new ObjectId(matchId) });
        if (!match) return res.status(404).json({ message: 'Match not found' });
        if (match.status !== 'pending') return res.status(400).json({ message: 'Already handled' });
        if (!match.opponentId?.equals(myId) && !match.challengerId?.equals(myId)) {
            return res.status(403).json({ message: 'Not allowed' });
        }
        await matches().updateOne({ _id: match._id }, { $set: { status: 'cancelled' } });
        emitToUsers(
            [match.challengerId.toString(), match.opponentId.toString()],
            { type: 'game:challenge' }
        );
        res.status(200).json({ status: 'cancelled' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- match session ---------------- */

export const getMatch = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { matchId } = req.params;
        if (!ObjectId.isValid(matchId)) {
            return res.status(400).json({ message: 'Invalid match id' });
        }
        const match = await matches().findOne({ _id: new ObjectId(matchId) });
        if (!match) return res.status(404).json({ message: 'Match not found' });

        const meIdx = match.players.findIndex((p) => p.userId.equals(myId));
        if (meIdx === -1) return res.status(403).json({ message: 'Not your match' });
        const oppIdx = meIdx === 0 ? 1 : 0;

        const userDocs = await users().find(
            { _id: { $in: match.players.map((p) => p.userId) } },
            { projection: USER_PUBLIC_PROJECTION }
        ).toArray();
        const userMap = new Map(userDocs.map((u) => [u._id.toString(), u]));

        const me = match.players[meIdx];
        const opp = match.players[oppIdx];

        // Only prompts go to the client, never the stored solutions.
        const rounds = (match.rounds || []).map((r) => ({ prompt: r.prompt }));

        res.status(200).json({
            _id: match._id,
            gameType: match.gameType,
            mode: match.mode,
            status: match.status,
            roundsCount: rounds.length,
            rounds,
            me: {
                user: userMap.get(me.userId.toString()) || null,
                score: me.score,
                submissionsCount: me.submissions?.length || 0,
                finishedAt: me.finishedAt || null,
                ratingBefore: me.ratingBefore ?? null,
                ratingAfter: me.ratingAfter ?? null
            },
            opponent: {
                user: userMap.get(opp.userId.toString()) || null,
                score: match.status === 'finished' ? opp.score : undefined,
                submissionsCount: opp.submissions?.length || 0,
                finishedAt: opp.finishedAt || null,
                ratingBefore: opp.ratingBefore ?? null,
                ratingAfter: opp.ratingAfter ?? null
            },
            winnerId: match.winnerId || null,
            isWinner: match.winnerId ? match.winnerId.equals(myId) : null
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const submitAnswer = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { matchId } = req.params;
        const { roundIndex, answer } = req.body;
        if (!ObjectId.isValid(matchId)) {
            return res.status(400).json({ message: 'Invalid match id' });
        }
        const match = await matches().findOne({ _id: new ObjectId(matchId) });
        if (!match) return res.status(404).json({ message: 'Match not found' });
        if (match.status !== 'active') return res.status(400).json({ message: 'Match is not active' });

        const meIdx = match.players.findIndex((p) => p.userId.equals(myId));
        if (meIdx === -1) return res.status(403).json({ message: 'Not your match' });

        const engine = getEngine(match.gameType);
        const me = match.players[meIdx];
        const subs = me.submissions || [];
        const idx = typeof roundIndex === 'number' ? roundIndex : subs.length;

        if (idx !== subs.length) {
            return res.status(400).json({ message: 'Out-of-order submission' });
        }
        if (idx >= match.rounds.length) {
            return res.status(400).json({ message: 'All rounds already submitted' });
        }

        const points = engine.score(match.rounds[idx].solution, answer);
        const newSubs = [...subs, { answer, points }];
        const newScore = newSubs.reduce((sum, s) => sum + s.points, 0);
        const finished = newSubs.length >= match.rounds.length;

        const set = {
            [`players.${meIdx}.submissions`]: newSubs,
            [`players.${meIdx}.score`]: newScore
        };
        if (finished) set[`players.${meIdx}.finishedAt`] = new Date();

        await matches().updateOne({ _id: match._id }, { $set: set });

        const oppId = match.players[meIdx === 0 ? 1 : 0].userId;
        emitToUsers([oppId.toString()], { type: 'game:update', matchId });

        if (finished) {
            const updated = await matches().findOne({ _id: match._id });
            await finalizeIfDone(updated);
        }

        res.status(200).json({ points, score: newScore, finished });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const forfeitMatch = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { matchId } = req.params;
        if (!ObjectId.isValid(matchId)) {
            return res.status(400).json({ message: 'Invalid match id' });
        }
        const match = await matches().findOne({ _id: new ObjectId(matchId) });
        if (!match) return res.status(404).json({ message: 'Match not found' });
        if (match.status !== 'active') return res.status(400).json({ message: 'Match is not active' });

        const meIdx = match.players.findIndex((p) => p.userId.equals(myId));
        if (meIdx === -1) return res.status(403).json({ message: 'Not your match' });

        const winnerId = match.players[meIdx === 0 ? 1 : 0].userId;
        const outcomeA = meIdx === 0 ? 0 : 1; // forfeiter loses
        await applyResult(match, winnerId, outcomeA);
        res.status(200).json({ status: 'finished' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- ratings / leaderboard / history ---------------- */

export const getRatings = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const r = await ratings().find({ userId: myId }).toArray();
        res.status(200).json(r);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getLeaderboard = async (req, res) => {
    try {
        const { gameType } = req.params;
        if (!getEngine(gameType)) {
            return res.status(400).json({ message: 'Unknown game' });
        }
        const top = await ratings().aggregate([
            { $match: { gameType } },
            { $sort: { rating: -1 } },
            { $limit: 20 },
            {
                $lookup: {
                    from: 'users',
                    localField: 'userId',
                    foreignField: '_id',
                    as: 'user',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: '$user' },
            { $project: { _id: 0, rating: 1, played: 1, won: 1, lost: 1, user: 1 } }
        ]).toArray();
        res.status(200).json(top);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getHistory = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const list = await matches().find(
            { status: 'finished', 'players.userId': myId },
            { projection: { rounds: 0 }, sort: { finishedAt: -1 }, limit: 20 }
        ).toArray();

        const shaped = list.map((m) => {
            const meIdx = m.players.findIndex((p) => p.userId.equals(myId));
            const oppIdx = meIdx === 0 ? 1 : 0;
            return {
                _id: m._id,
                gameType: m.gameType,
                mode: m.mode,
                myScore: m.players[meIdx].score,
                oppScore: m.players[oppIdx].score,
                result: m.winnerId ? (m.winnerId.equals(myId) ? 'win' : 'loss') : 'draw',
                ratingAfter: m.players[meIdx].ratingAfter ?? null,
                finishedAt: m.finishedAt
            };
        });
        res.status(200).json(shaped);
    } catch (error) {
        handleServerError(res, error);
    }
};
CRYSTAL_EOF_5B7D2C10
echo "  wrote backend/src/modules/game/game.controller.js"

mkdir -p "frontend/src/pages/GamesPage/games"
cat > "frontend/src/pages/GamesPage/games/MathSprint.jsx" << 'CRYSTAL_EOF_5B7D2C10'
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
CRYSTAL_EOF_5B7D2C10
echo "  wrote frontend/src/pages/GamesPage/games/MathSprint.jsx"

mkdir -p "frontend/src/pages/GamesPage/games"
cat > "frontend/src/pages/GamesPage/games/MathSprint.module.css" << 'CRYSTAL_EOF_5B7D2C10'
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

.timer {
  text-align: center;
  font-size: 14px;
  color: var(--separator_color_global);
  margin-bottom: 14px;
}

.question {
  text-align: center;
  font-size: 40px;
  font-weight: 800;
  color: var(--color_global);
  margin-bottom: 22px;
  font-variant-numeric: tabular-nums;
}

.input {
  display: block;
  margin: 0 auto;
  width: 200px;
  padding: 12px 16px;
  font-size: 24px;
  text-align: center;
  border-radius: 12px;
  border: var(--border_global);
  background-color: var(--background-color_global);
  color: var(--color_global);
  outline: none;
}

.input:focus { border-color: var(--hashtag_color_global); }

.submit {
  display: block;
  margin: 20px auto 0;
  padding: 12px 32px;
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
CRYSTAL_EOF_5B7D2C10
echo "  wrote frontend/src/pages/GamesPage/games/MathSprint.module.css"

mkdir -p "frontend/src/pages/GamesPage"
cat > "frontend/src/pages/GamesPage/GamesPage.jsx" << 'CRYSTAL_EOF_5B7D2C10'
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

import styles from './GamesPage.module.css';

export const GAMES = [
  { key: 'colorGuess', name: 'Color Guess', emoji: '🎨', description: 'A color is shown — guess its RGB. Closest wins.', available: true },
  { key: 'math', name: 'Math Sprint', emoji: '🔢', description: 'Rapid-fire number puzzles.', available: true },
  { key: 'frequency', name: 'Frequency', emoji: '🔊', description: 'Hear a tone, guess the Hz.', available: false },
  { key: 'wordle', name: 'Wordle Duel', emoji: '🟩', description: 'Race to crack the word.', available: false },
  { key: 'sudoku', name: 'Sudoku', emoji: '🧩', description: 'Solve faster than your rival.', available: false },
  { key: 'zip', name: 'Zip', emoji: '➿', description: 'Connect 1→N through every cell.', available: false }
];

const BOARDS = { colorGuess: ColorGuess, math: MathSprint };

const gameName = (key) => GAMES.find((g) => g.key === key)?.name || key;

function Avatar({ user, size = 38 }) {
  const style = { width: size, height: size };
  if (user?.avatarUri) {
    return <img className={styles.avatar} style={style} src={API_BASE_URL + user.avatarUri} alt={user.name} />;
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
CRYSTAL_EOF_5B7D2C10
echo "  wrote frontend/src/pages/GamesPage/GamesPage.jsx"

mkdir -p "frontend/public/locales/en"
cat > "frontend/public/locales/en/translation.json" << 'CRYSTAL_EOF_5B7D2C10'
{
  "SystemMessages": {
    "Error": "Error"
  },
  "Common": {
    "LargeImageError": "❌ Maximum GIF size - 2.5MB",
    "UploadingImageError": "❌ Error uploading image."
  },
  "AccessModal": {
    "SwitchLogIn": "Log In",
    "SwitchSignUp": "Sign Up",
    "InputNameLogIn": "Name",
    "InputNameSignUp": "Name",
    "InputErrorNameEmpty": "Enter a name",
    "InputErrorNameMinimumLength": "The minimum length of the name is 1 character",
    "InputErrorNameMaximumLength": "The maximum length of the name is 200 characters",
    "InputErrorIdAlreadyExists": "This Id already exists",
    "InputErrorIdMinimumLength": "Minimum length of Id - 1 character",
    "InputErrorIdMaximumLength": "Maximum length of Id - 35 characters",
    "InputErrorIdMinimumMaximumLengthSymbols": "Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed",
    "InputEmail": "Email",
    "InputErrorEmailMaximumLength": "The maximum length of an email is 100 characters",
    "InputErrorEmailAlreadyExists": "This email already exists",
    "InputPasswordLogIn": "Password",
    "InputPasswordSignUp": "* Password",
    "InputErrorEmailEmpty": "Enter email",
    "InputErrorPasswordEmpty": "Enter password",
    "InputErrorPasswordMinimumMaximumLengthSymbols": "The minimum password length is 8 characters, the maximum is 50, Latin letters, numbers and special characters are allowed",
    "InputErrorEmailPasswordWrong": "Invalid email or password",
    "InputErrorAcceptTerms": "It is necessary to accept the conditions",
    "Terms": "I accept the <1>terms of user agreement</1>, <2>privacy policy</2> and <3>cookies policy</3>."
  },
  "User": {
    "UserDeleted": "User deleted"
  },
  "PostCreatePage": {
    "CreatePost": "Create a post",
    "Text": "Text",
    "Title": "Title",
    "AddMainImage": "Add image",
    "ChangeMainImage": "Change",
    "DeleteMainImage": "Delete",
    "Publish": "Publish",
    "Back": "Back",
    "FailedCreatePost": "Failed to create post"
  },
  "PostEditPage": {
    "EditPost": "Edit post",
    "AddMainImage": "Add image",
    "Change": "Change",
    "Delete": "Delete",
    "Publish": "Publish",
    "Text": "Text",
    "Title": "Title",
    "Back": "Back",
    "FailedSaveChanges": "Failed to save changes"
  },
  "UserEditPage": {
    "EditUser": "Editing user and settings",
    "Settings": "Settings",
    "Interface": "Interface",
    "Privacy": "Privacy",
    "HideGif": "Hide GIF",
    "ShowGif": "Show GIF",
    "UserName": "Name",
    "UserBio": "About me",
    "DeleteAllYourPostsButton": "Delete all posts",
    "DeleteAllUserPostsButton": "Delete all posts",
    "DeleteAllYourPosts": "Delete all posts ? Posts will be deleted without the possibility of recovery.",
    "DeleteAllPostsByUser": "Delete all user posts ? Posts will be deleted permanently.",
    "AllPostsDeleted": "All posts deleted",
    "DeleteAccount": "Delete account",
    "DeleteAccountQuestion": "Delete user account ? The account will be deleted without the possibility of recovery.",
    "DeleteUserAccount": "Delete user account",
    "SaveChanges": "Save changes",
    "Save": "Save",
    "IdErrorMinimumMaximumLengthSymbols": "Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed",
    "IdAlreadyExists": "This Id already exists",
    "ChangePassword": "Change password",
    "Hide": "Hide",
    "OldPassword": "Old password",
    "NewPassword": "New password",
    "OldPasswordIncorrect": "Old password is incorrect",
    "PasswordRequirements": "The password may contain Latin letters, numbers and special characters.",
    "PasswordSuccessfullyChanged": "Password successfully changed",
    "Gender": "Gender",
    "Female": "female",
    "Male": "male",
    "Unspecified": "unspecified",
    "CustomGender": "Self-identify",
    "GenderError": "Floor update error.",
    "GenderSelectionNotAvailable": "Gender selection feature is not available",
    "HideGender": "Hide Gender",
    "ShowGender": "Show Gender"
  },
  "CookiesBanner": {
    "Text": "This website uses cookies. By clicking the 'Accept' button or continuing to use the website, you agree to the use of cookies.",
    "ButtonMoreDetails": "More details",
    "ButtonAccept": "Accept"
  },
  "SideMenuDesktop": {
    "MyProfile": "My profile",
    "Messages": "Messages",
    "Friends": "Friends",
    "Communities": "Communities",
    "Photo": "Photo",
    "Video": "Video",
    "Likes": "Likes",
    "Settings": "Settings",
    "Bookmarks": "Bookmarks",
    "AboutCrystal": "About Crystal",
    "Agreements": "Agreements",
    "Help": "Help",
    "Games": "Games"
  },
  "SideMenuMobile": {
    "MyProfile": "My profile",
    "Messages": "Messages",
    "Friends": "Friends",
    "Communities": "Communities",
    "Photo": "Photo",
    "Video": "Video",
    "Likes": "Likes",
    "Bookmarks": "Bookmarks",
    "AboutCrystal": "About Crystal",
    "Agreements": "Agreements",
    "Help": "Help"
  },
  "CurrentTopics": {
    "CurrentTopics": "Current topics",
    "ShowMore": "Show more",
    "Post": "Post",
    "PostsAverage": "Posts",
    "Posts": "posts",
    "key_one": "post",
    "key_other": "posts"
  },
  "RecommendedUsers": {
    "YouMightLike": "You might like",
    "Subscribe": "Subscribe",
    "ShowMore": "Show more"
  },
  "OptionsMenuGuest": {
    "AboutCrystal": "About CRYSTAL",
    "Agreements": "Agreements",
    "Help": "Help"
  },
  "PostSourceMenu": {
    "Subscriptions": "Subscriptions",
    "Preferences": "Preferences",
    "Mine": "Mine",
    "World": "World"
  },
  "OptionsMenuUser": {
    "MyProfile": "My profile",
    "Settings": "Settings",
    "Agreements": "Agreements",
    "Help": "Help",
    "Exit": "Exit",
    "LogOut": "Log out of your account ?"
  },
  "PostPreview": {
    "DeleteAccountQuestion": "Delete user account ?",
    "DeleteAllUserPostsQuestion": "Delete all posts by user?",
    "DeletePostQuestion": "Delete post ?",
    "UserDeleted": "User deleted",
    "EditPost": "Edit",
    "DeletePost": "Delete",
    "DeleteAllUserPosts": "Delete all user posts",
    "DeleteUser": "Delete user",
    "add": "add",
    "upd": "upd"
  },
  "FullPostPage": {
    "DeleteAccountQuestion": "Delete user account ?",
    "DeleteAllUserPostsQuestion": "Delete all posts by user?",
    "DeletePostQuestion": "Delete post ?",
    "UserDeleted": "User deleted",
    "EditPost": "Edit",
    "DeletePost": "Delete",
    "DeleteAllUserPosts": "Delete all user posts",
    "DeleteUser": "Delete user",
    "add": "add",
    "upd": "upd"
  },
  "UserInformation": {
    "EditUser": "Edit",
    "FailedDeleteAvatar": "❌ Failed to delete avatar",
    "FailedDeleteBanner": "❌ Failed to delete banner",
    "ShowMore": "Show more",
    "Hide": "Hide"
  },
  "LikesPage": {
    "LikedPosts": "Likes",
    "NolikedPosts": "No liked posts"
  },
  "MoreAboutUserModal": {
    "DetailedInformation": "Detailed information",
    "Gender": "Gender",
    "Female": "female",
    "Male": "male",
    "Unspecified": "unspecified",
    "Registration": "Registration date",
    "Update": "Update"
  },
  "UseFormattedLastSeenDateShort": {
    "seconds": "s",
    "minutes": "min",
    "hours": "h",
    "days": "d",
    "months": "mon",
    "key_one": "y",
    "key_other": "y"
  },
  "UseFormattedLastSeenDate": {
    "prefix": "Last seen",
    "ago": "ago",
    "yesterday": "yesterday",
    "at": "at",
    "seconds_one": "second",
    "seconds_other": "seconds",
    "minutes_one": "minute",
    "minutes_other": "minutes",
    "hours_one": "hour",
    "hours_other": "hours"
  },
  "SearchPage": {
    "SearchResultsFor": "Search results for:",
    "NothingFoundFor": "Nothing found for:",
    "EnterYourSearchTerm": "Enter your search term"
  },
  "MessagesPage": {
    "Messages": "Messages",
    "NoConversations": "No conversations yet",
    "NoMessages": "No messages yet. Say hello!",
    "TypeMessage": "Type a message...",
    "LoadError": "Could not load messages",
    "Unknown": "Unknown user"
  },
  "CommunitiesPage": {
    "Communities": "Communities",
    "Create": "Create",
    "NamePlaceholder": "Community name",
    "DescriptionPlaceholder": "Description (optional)",
    "NoCommunities": "No communities yet. Create the first one!",
    "Members": "members",
    "Open": "Open",
    "Join": "Join",
    "Leave": "Leave",
    "JoinToChat": "Join this community to read and send messages",
    "NoMessages": "No messages yet. Start the conversation!",
    "TypeMessage": "Type a message...",
    "LoadError": "Could not load communities",
    "Unknown": "Unknown user",
    "PrivateLabel": "Private (approval required to join)",
    "Requested": "Requested",
    "RequestToJoin": "Request to join",
    "RequestPending": "Your request is awaiting approval",
    "RequestToChat": "Request to join this community to read and send messages",
    "JoinRequests": "Join requests",
    "Approve": "Approve",
    "Decline": "Decline"
  },
  "FriendsPage": {
    "Friends": "Friends",
    "FindPeople": "Find people",
    "SearchPlaceholder": "Search by name or @id...",
    "NoResults": "No people found",
    "Requests": "Friend requests",
    "Sent": "Sent requests",
    "MyFriends": "My friends",
    "NoFriends": "You have no friends yet. Find people above!",
    "AddFriend": "Add friend",
    "Requested": "Requested",
    "Accept": "Accept",
    "Decline": "Decline",
    "Cancel": "Cancel",
    "Message": "Message",
    "Remove": "Remove"
  },
  "ProfileActions": {
    "Message": "Message",
    "AddFriend": "Add friend",
    "Requested": "Requested",
    "Accept": "Accept",
    "Friends": "Friends ✓"
  },
  "GamesPage": {
    "Games": "Games",
    "Soon": "Soon",
    "YourRating": "Your rating",
    "FindMatch": "Find match",
    "Searching": "Searching for an opponent...",
    "Cancel": "Cancel",
    "Challenges": "Challenges",
    "Accept": "Accept",
    "Decline": "Decline",
    "ChallengeFriend": "Challenge a friend",
    "Challenge": "Challenge",
    "Sent": "Sent",
    "NoFriends": "Add friends to challenge them.",
    "Leaderboard": "Leaderboard",
    "NoRanking": "No ranked players yet. Be the first!",
    "You": "You",
    "Opponent": "Opponent",
    "Round": "Round",
    "Done": "Done",
    "WaitingOpponent": "Waiting for your opponent to finish...",
    "WaitingAccept": "Waiting for your opponent to accept...",
    "MatchError": "Could not load this match",
    "Won": "You won!",
    "Lost": "You lost",
    "Draw": "Draw",
    "Rating": "Rating",
    "Rematch": "Rematch",
    "BackToLobby": "Back to lobby",
    "Forfeit": "Forfeit",
    "SubmitGuess": "Submit guess",
    "ColorShown": "Shown",
    "ColorYourGuess": "Your guess",
    "Submit": "Submit"
  }
}
CRYSTAL_EOF_5B7D2C10
echo "  wrote frontend/public/locales/en/translation.json"

mkdir -p "frontend/public/locales/ru"
cat > "frontend/public/locales/ru/translation.json" << 'CRYSTAL_EOF_5B7D2C10'
{
  "SystemMessages": {
    "Error": "Ошибка"
  },
  "Common": {
    "LargeImageError": "❌ Максимальный размер GIF - 2.5MB",
    "UploadingImageError": "❌ Ошибка при загрузке изображения."
  },
  "AccessModal": {
    "SwitchLogIn": "Войти",
    "SwitchSignUp": "Регистрация",
    "InputNameLogIn": "Имя",
    "InputNameSignUp": "Имя",
    "InputErrorNameEmpty": "Введите имя",
    "InputErrorNameMinimumLength": "Минимальная длина имени - 1 символ",
    "InputErrorNameMaximumLength": "Максимальная длина имени - 200 символов",
    "InputErrorIdAlreadyExists": "Этот Id уже существует",
    "InputErrorIdMinimumLength": "Минимальная длина Id - 1 символ",
    "InputErrorIdMaximumLength": "Максимальная длина Id - 35 символов",
    "InputErrorIdMinimumMaximumLengthSymbols": "Минимальная длина id - 1 символ, максимальная - 35, допускаются латинские буквы, цифры, нижние подчеркивания и тире",
    "InputEmail": "* Email",
    "InputErrorEmailEmpty": "Введите email",
    "InputErrorEmailMaximumLength": "Максимальная длина email - 100 символов",
    "InputErrorEmailAlreadyExists": "Этот email уже существует",
    "InputPasswordLogIn": "Пароль",
    "InputPasswordSignUp": "* Пароль",
    "InputErrorPasswordEmpty": "Введите пароль",
    "InputErrorPasswordMinimumMaximumLengthSymbols": "Минимальная длина пароля - 8 символов, максимальная - 50, допускаются латинские буквы, цифры и специальные символы",
    "InputErrorEmailPasswordWrong": "Неверная почта или пароль",
    "InputErrorAcceptTerms": "Необходимо принять условия",
    "Terms": "Я принимаю <1>условия пользовательского соглашения</1>, <2>политику конфиденциальности</2> и <3>политику использования файлов cookies</3>."
  },
  "User": {
    "UserDeleted": "Пользователь удалён"
  },
  "PostCreatePage": {
    "CreatePost": "Создать пост",
    "Text": "Текст",
    "Title": "Заголовок",
    "AddMainImage": "Добавить изображение",
    "ChangeMainImage": "Изменить",
    "DeleteMainImage": "Удалить",
    "Publish": "Опубликовать",
    "Back": "Назад",
    "FailedCreatePost": "Не удалось создать пост."
  },
  "PostEditPage": {
    "EditPost": "Редактирование поста",
    "AddMainImage": "Добавить изображение",
    "Change": "Изменить",
    "Delete": "Удалить",
    "Publish": "Опубликовать",
    "Text": "Текст",
    "Title": "Заголовок",
    "Back": "Назад",
    "FailedSaveChanges": "Не удалось сохранить изменения"
  },
  "UserEditPage": {
    "EditUser": "Редактирование пользователя и настройки",
    "Settings": "Настройки",
    "Interface": "Интерфейс",
    "Privacy": "Конфиденциальность",
    "HideGif": "Скрыть GIF",
    "ShowGif": "Показать GIF",
    "UserName": "Имя",
    "UserBio": "О себе",
    "DeleteAllYourPostsButton": "Удалить все посты",
    "DeleteAllUserPostsButton": "Удалить все посты",
    "DeleteAllYourPosts": "Удалить все посты ? Посты будут удалены без возможности восстановления.",
    "DeleteAllPostsByUser": "Удалить все посты пользователя ? Посты будут удалены без возможности восстановления.",
    "AllPostsDeleted": "Все посты удалены",
    "DeleteAccount": "Удалить аккаунт",
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ? Аккаунт будет удален без возможности восстановления.",
    "DeleteUserAccount": "Удалить аккаунт пользователя",
    "SaveChanges": "Сохранить изменения",
    "Save": "Сохранить",
    "IdErrorMinimumMaximumLengthSymbols": "Минимальная длина id - 1 символ, максимальная - 35, допускаются латинские буквы, цифры, нижние подчеркивания и тире",
    "IdAlreadyExists": "Этот Id уже существует",
    "ChangePassword": "Изменить пароль",
    "Hide": "Скрыть",
    "OldPassword": "Старый пароль",
    "NewPassword": "Новый пароль",
    "OldPasswordIncorrect": "Старый пароль - неверный",
    "PasswordRequirements": "В пароле допускаются латинские буквы, цифры и специальные символы.",
    "PasswordSuccessfullyChanged": "Пароль успешно изменён",
    "Gender": "Пол",
    "Female": "женский",
    "Male": "мужской",
    "Unspecified": "не указан",
    "CustomGender": "Самоопределение",
    "GenderError": "Ошибка обновления пола.",
    "GenderSelectionNotAvailable": "Функция выбора пола недоступна",
    "HideGender": "Скрыть пол",
    "ShowGender": "Показать пол"
  },
  "CookiesBanner": {
    "Text": "Этот сайт использует файлы cookies. Нажимая кнопку 'Принять' или продолжая пользоваться сайтом, вы соглашаетесь на использование файлов cookies.",
    "ButtonMoreDetails": "Подробнее",
    "ButtonAccept": "Принять"
  },
  "SideMenuDesktop": {
    "MyProfile": "Мой профиль",
    "Messages": "Сообщения",
    "Friends": "Друзья",
    "Communities": "Сообщества",
    "Photo": "Фото",
    "Video": "Видео",
    "Likes": "Нравится",
    "Settings": "Настройки",
    "Bookmarks": "Закладки",
    "AboutCrystal": "О Crystal",
    "Agreements": "Соглашения",
    "Help": "Помощь",
    "Games": "Игры"
  },
  "SideMenuMobile": {
    "MyProfile": "Мой профиль",
    "Messages": "Сообщения",
    "Friends": "Друзья",
    "Communities": "Сообщества",
    "Photo": "Фото",
    "Video": "Видео",
    "Likes": "Нравится",
    "Bookmarks": "Закладки",
    "AboutCrystal": "О Crystal",
    "Agreements": "Соглашения",
    "Help": "Помощь"
  },
  "CurrentTopics": {
    "CurrentTopics": "Актуальные темы",
    "ShowMore": "Посмотреть еще",
    "Post": "Пост",
    "PostsAverage": "Поста",
    "Posts": "постов",
    "key_one": "пост",
    "key_few": "поста",
    "key_many": "постов"
  },
  "RecommendedUsers": {
    "YouMightLike": "Вам может понравиться",
    "Subscribe": "Подписаться",
    "ShowMore": "Посмотреть еще"
  },
  "OptionsMenuGuest": {
    "AboutCrystal": "О CRYSTAL",
    "Agreements": "Соглашения",
    "Help": "Помощь"
  },
  "PostSourceMenu": {
    "Subscriptions": "Подписки",
    "Preferences": "Предпочтения",
    "Mine": "Мои",
    "World": "Мир"
  },
  "OptionsMenuUser": {
    "MyProfile": "Мой профиль",
    "Settings": "Настройки",
    "Agreements": "Соглашения",
    "Help": "Помощь",
    "Exit": "Выход",
    "LogOut": "Выйти из аккаунта ?"
  },
  "PostPreview": {
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ?",
    "DeleteAllUserPostsQuestion": "Удалить все посты пользователя ?",
    "DeletePostQuestion": "Удалить пост ?",
    "UserDeleted": "Пользователь удален",
    "EditPost": "Редактировать",
    "DeletePost": "Удалить",
    "DeleteAllUserPosts": "Удалить все посты пользователя",
    "DeleteUser": "Удалить пользователя",
    "add": "доб",
    "upd": "обн"
  },
  "FullPostPage": {
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ?",
    "DeleteAllUserPostsQuestion": "Удалить все посты пользователя ?",
    "DeletePostQuestion": "Удалить пост ?",
    "UserDeleted": "Пользователь удален",
    "EditPost": "Редактировать",
    "DeletePost": "Удалить",
    "DeleteAllUserPosts": "Удалить все посты пользователя",
    "DeleteUser": "Удалить пользователя",
    "add": "доб",
    "upd": "обн"
  },
  "UserInformation": {
    "EditUser": "Редактировать",
    "FailedDeleteAvatar": "❌ Не удалось удалить аватар",
    "FailedDeleteBanner": "❌ Не удалось удалить баннер",
    "ShowMore": "Подробнее",
    "Hide": "Скрыть"
  },
  "LikesPage": {
    "LikedPosts": "Нравится",
    "NolikedPosts": "Нет понравившихся постов"
  },
  "MoreAboutUserModal": {
    "DetailedInformation": "Подробная информация",
    "Gender": "Пол",
    "Female": "женский",
    "Male": "мужской",
    "Unspecified": "не указан",
    "Registration": "Дата регистрации",
    "Update": "Обновление"
  },
  "UseFormattedLastSeenDateShort": {
    "seconds": "с",
    "minutes": "мин",
    "hours": "ч",
    "days": "д",
    "months": "мес",
    "key_one": "г",
    "key_few": "г",
    "key_many": "л",
    "key_other": "л"
  },
  "UseFormattedLastSeenDate": {
    "prefix_male": "Заходил",
    "prefix_female": "Заходила",
    "prefix_unspecified": "Заходил(а)",
    "ago": "назад",
    "yesterday": "вчера",
    "at": "в",
    "seconds_one": "секунду",
    "seconds_few": "секунды",
    "seconds_many": "секунд",
    "minutes_one": "минуту",
    "minutes_few": "минуты",
    "minutes_many": "минут",
    "hours_one": "час",
    "hours_few": "часа",
    "hours_many": "часов"
  },
  "SearchPage": {
    "SearchResultsFor": "Результаты поиска для:",
    "NothingFoundFor": "Ничего не найдено для:",
    "EnterYourSearchTerm": "Введите запрос для поиска"
  },
  "MessagesPage": {
    "Messages": "Сообщения",
    "NoConversations": "Пока нет диалогов",
    "NoMessages": "Сообщений пока нет. Поздоровайтесь!",
    "TypeMessage": "Введите сообщение...",
    "LoadError": "Не удалось загрузить сообщения",
    "Unknown": "Неизвестный пользователь"
  },
  "CommunitiesPage": {
    "Communities": "Сообщества",
    "Create": "Создать",
    "NamePlaceholder": "Название сообщества",
    "DescriptionPlaceholder": "Описание (необязательно)",
    "NoCommunities": "Пока нет сообществ. Создайте первое!",
    "Members": "участников",
    "Open": "Открыть",
    "Join": "Вступить",
    "Leave": "Покинуть",
    "JoinToChat": "Вступите в сообщество, чтобы читать и отправлять сообщения",
    "NoMessages": "Сообщений пока нет. Начните общение!",
    "TypeMessage": "Введите сообщение...",
    "LoadError": "Не удалось загрузить сообщества",
    "Unknown": "Неизвестный пользователь",
    "PrivateLabel": "Приватное (нужно одобрение для вступления)",
    "Requested": "Заявка отправлена",
    "RequestToJoin": "Подать заявку",
    "RequestPending": "Ваша заявка ожидает одобрения",
    "RequestToChat": "Подайте заявку на вступление, чтобы читать и отправлять сообщения",
    "JoinRequests": "Заявки на вступление",
    "Approve": "Принять",
    "Decline": "Отклонить"
  },
  "FriendsPage": {
    "Friends": "Друзья",
    "FindPeople": "Найти людей",
    "SearchPlaceholder": "Поиск по имени или @id...",
    "NoResults": "Никого не найдено",
    "Requests": "Заявки в друзья",
    "Sent": "Отправленные заявки",
    "MyFriends": "Мои друзья",
    "NoFriends": "У вас пока нет друзей. Найдите людей выше!",
    "AddFriend": "Добавить",
    "Requested": "Отправлено",
    "Accept": "Принять",
    "Decline": "Отклонить",
    "Cancel": "Отменить",
    "Message": "Написать",
    "Remove": "Удалить"
  },
  "ProfileActions": {
    "Message": "Написать",
    "AddFriend": "Добавить",
    "Requested": "Заявка отправлена",
    "Accept": "Принять",
    "Friends": "В друзьях ✓"
  },
  "GamesPage": {
    "Games": "Игры",
    "Soon": "Скоро",
    "YourRating": "Ваш рейтинг",
    "FindMatch": "Найти соперника",
    "Searching": "Поиск соперника...",
    "Cancel": "Отмена",
    "Challenges": "Вызовы",
    "Accept": "Принять",
    "Decline": "Отклонить",
    "ChallengeFriend": "Вызвать друга",
    "Challenge": "Вызвать",
    "Sent": "Отправлено",
    "NoFriends": "Добавьте друзей, чтобы вызывать их.",
    "Leaderboard": "Таблица лидеров",
    "NoRanking": "Пока нет игроков. Будьте первым!",
    "You": "Вы",
    "Opponent": "Соперник",
    "Round": "Раунд",
    "Done": "Готово",
    "WaitingOpponent": "Ожидание соперника...",
    "WaitingAccept": "Ожидание принятия вызова...",
    "MatchError": "Не удалось загрузить матч",
    "Won": "Победа!",
    "Lost": "Поражение",
    "Draw": "Ничья",
    "Rating": "Рейтинг",
    "Rematch": "Реванш",
    "BackToLobby": "В лобби",
    "Forfeit": "Сдаться",
    "SubmitGuess": "Отправить",
    "ColorShown": "Показано",
    "ColorYourGuess": "Ваша догадка",
    "Submit": "Ответить"
  }
}
CRYSTAL_EOF_5B7D2C10
echo "  wrote frontend/public/locales/ru/translation.json"

echo ""
echo "Done. Math Sprint added."
