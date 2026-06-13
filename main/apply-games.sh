#!/usr/bin/env bash
# Adds the Games framework + Color Guess to crystal-v2.0.
# Run from the repo "main/" directory:  bash apply-games.sh
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then echo "ERROR: run this from ~/crystal-v2.0/main"; exit 1; fi

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/prng.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/engine/prng.js
// Small deterministic PRNG so both players get an identical challenge from one seed.

export function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
        a |= 0;
        a = (a + 0x6D2B79F5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

export function makeSeed() {
    return Math.floor(Math.random() * 2 ** 31);
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/engine/prng.js"

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/elo.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/engine/elo.js

const DEFAULT_K = 32;

export function expectedScore(ratingA, ratingB) {
    return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

// outcomeA: 1 = A wins, 0 = A loses, 0.5 = draw
export function newRating(ratingA, ratingB, outcomeA, k = DEFAULT_K) {
    return Math.round(ratingA + k * (outcomeA - expectedScore(ratingA, ratingB)));
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/engine/elo.js"

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/colorGuess.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/engine/colorGuess.js
// A color is shown; the player guesses its RGB values. Closest guess scores higher.

import { mulberry32 } from './prng.js';

const ROUNDS = 5;
const MAX_DIST = Math.sqrt(3 * 255 * 255); // max RGB euclidean distance

function genColor(rng) {
    return {
        r: Math.floor(rng() * 256),
        g: Math.floor(rng() * 256),
        b: Math.floor(rng() * 256)
    };
}

export const colorGuess = {
    key: 'colorGuess',
    rounds: ROUNDS,

    // Build all rounds deterministically from a seed.
    // For this game the shown color IS the solution (the player must see it to guess).
    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const target = genColor(rng);
            rounds.push({ prompt: { type: 'color', target }, solution: target });
        }
        return rounds;
    },

    // Score one guess against the solution: 0..100 (100 = exact).
    score(solution, answer) {
        if (!answer || typeof answer.r !== 'number' || typeof answer.g !== 'number' || typeof answer.b !== 'number') {
            return 0;
        }
        const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
        const dr = clamp(answer.r) - solution.r;
        const dg = clamp(answer.g) - solution.g;
        const db = clamp(answer.b) - solution.b;
        const dist = Math.sqrt(dr * dr + dg * dg + db * db);
        return Math.round(100 * (1 - dist / MAX_DIST));
    }
};
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/engine/colorGuess.js"

mkdir -p "backend/src/modules/game/engine"
cat > "backend/src/modules/game/engine/index.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/engine/index.js
// Registry of playable games. Add new games here as they are implemented.

import { colorGuess } from './colorGuess.js';

export const GAME_ENGINES = {
    colorGuess
};

export function getEngine(gameType) {
    return GAME_ENGINES[gameType] || null;
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/engine/index.js"

mkdir -p "backend/src/modules/game"
cat > "backend/src/modules/game/game.schema.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/game.schema.js

export const GAME_MATCH_SCHEMA = {
    bsonType: 'object',
    required: ['gameType', 'mode', 'status', 'players', 'createdAt'],
    properties: {
        gameType: { bsonType: 'string' },
        mode: { enum: ['ranked', 'casual'] },
        status: { enum: ['pending', 'active', 'finished', 'cancelled'] },
        seed: { bsonType: ['int', 'long', 'double'] },
        rounds: { bsonType: 'array', items: { bsonType: 'object' } },
        players: {
            bsonType: 'array',
            items: { bsonType: 'object' },
            description: 'two player sub-documents { userId, score, finishedAt, submissions }'
        },
        challengerId: { bsonType: 'objectId' },
        opponentId: { bsonType: 'objectId' },
        winnerId: { bsonType: ['objectId', 'null'] },
        createdAt: { bsonType: 'date' },
        finishedAt: { bsonType: 'date' }
    }
};

export const GAME_MATCH_INDEXES = [
    { key: { status: 1 } },
    { key: { 'players.userId': 1, status: 1 } },
    { key: { opponentId: 1, status: 1 } },
    { key: { createdAt: -1 } }
];

export const GAME_RATING_SCHEMA = {
    bsonType: 'object',
    required: ['userId', 'gameType', 'rating', 'played', 'won', 'lost', 'updatedAt'],
    properties: {
        userId: { bsonType: 'objectId' },
        gameType: { bsonType: 'string' },
        rating: { bsonType: ['int', 'long', 'double'] },
        played: { bsonType: ['int', 'long'] },
        won: { bsonType: ['int', 'long'] },
        lost: { bsonType: ['int', 'long'] },
        drawn: { bsonType: ['int', 'long'] },
        updatedAt: { bsonType: 'date' }
    }
};

export const GAME_RATING_INDEXES = [
    { key: { userId: 1, gameType: 1 }, options: { unique: true } },
    { key: { gameType: 1, rating: -1 } }
];

export const GAME_QUEUE_SCHEMA = {
    bsonType: 'object',
    required: ['userId', 'gameType', 'mode', 'createdAt'],
    properties: {
        userId: { bsonType: 'objectId' },
        gameType: { bsonType: 'string' },
        mode: { enum: ['ranked', 'casual'] },
        createdAt: { bsonType: 'date' }
    }
};

export const GAME_QUEUE_INDEXES = [
    { key: { userId: 1, gameType: 1 }, options: { unique: true } },
    { key: { gameType: 1, createdAt: 1 } }
];
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/game.schema.js"

mkdir -p "backend/src/modules/game"
cat > "backend/src/modules/game/game.controller.js" << 'CRYSTAL_EOF_3E9A1F84'
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
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/game.controller.js"

mkdir -p "backend/src/modules/game"
cat > "backend/src/modules/game/games.routes.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/modules/game/games.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import * as controller from './game.controller.js';

const router = express.Router();

// static GETs first
router.get('/ratings', auth, controller.getRatings);
router.get('/history', auth, controller.getHistory);
router.get('/active', auth, controller.getActiveMatch);
router.get('/challenges', auth, controller.getChallenges);

// matchmaking
router.post('/queue', auth, controller.joinQueue);
router.post('/queue/leave', auth, controller.leaveQueue);
router.post('/challenge', auth, controller.createChallenge);

// match session (define before /:gameType/... )
router.get('/match/:matchId', auth, controller.getMatch);
router.post('/match/:matchId/accept', auth, controller.acceptChallenge);
router.post('/match/:matchId/decline', auth, controller.declineChallenge);
router.post('/match/:matchId/submit', auth, controller.submitAnswer);
router.post('/match/:matchId/forfeit', auth, controller.forfeitMatch);

// per-game leaderboard (param-first; keep last)
router.get('/:gameType/leaderboard', auth, controller.getLeaderboard);

export default router;
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/modules/game/games.routes.js"

mkdir -p "backend/src/core/engine/db"
cat > "backend/src/core/engine/db/initializeCollections.js" << 'CRYSTAL_EOF_3E9A1F84'
// src/core/engine/db/initializeCollections.js

import { USER_SCHEMA, USER_INDEXES } from '../../../modules/user/user.schema.js';
import { POST_SCHEMA, POST_INDEXES } from '../../../modules/post/post.schema.js';
import { HASHTAG_SCHEMA, HASHTAG_INDEXES } from '../../../modules/hashtag/hashtag.schema.js';
import { LIKE_SCHEMA, LIKE_INDEXES } from '../../../modules/like/like.schema.js';
import { MESSAGE_SCHEMA, MESSAGE_INDEXES } from '../../../modules/message/message.schema.js';
import {
    COMMUNITY_SCHEMA,
    COMMUNITY_INDEXES,
    COMMUNITY_MESSAGE_SCHEMA,
    COMMUNITY_MESSAGE_INDEXES
} from '../../../modules/community/community.schema.js';
import { FRIENDSHIP_SCHEMA, FRIENDSHIP_INDEXES } from '../../../modules/friend/friend.schema.js';
import {
    GAME_MATCH_SCHEMA,
    GAME_MATCH_INDEXES,
    GAME_RATING_SCHEMA,
    GAME_RATING_INDEXES,
    GAME_QUEUE_SCHEMA,
    GAME_QUEUE_INDEXES
} from '../../../modules/game/game.schema.js';

/**
 Asynchronously creates collections with $jsonSchema validation and sets all indexes.
 Called once at application startup (from connectDB.js).

  @param {import('mongodb').Db} db - The database object obtained via getDB().
 */
export async function initializeCollections(db) {
    console.log(" ⚙️ Initializing MongoDB collections and indexes...");

    // 1. User initialization
    await upsertCollection(db, 'users', USER_SCHEMA, USER_INDEXES);

    // 2. Initialization of posts
    await upsertCollection(db, 'posts', POST_SCHEMA, POST_INDEXES);

    // 3. Initializing hashtags
    await upsertCollection(db, 'hashtags', HASHTAG_SCHEMA, HASHTAG_INDEXES);

    // 4. Initializing likes
    await upsertCollection(db, 'likes', LIKE_SCHEMA, LIKE_INDEXES);

    // 5. Initializing messages (direct chat)
    await upsertCollection(db, 'messages', MESSAGE_SCHEMA, MESSAGE_INDEXES);

    // 6. Initializing communities (group chat rooms)
    await upsertCollection(db, 'communities', COMMUNITY_SCHEMA, COMMUNITY_INDEXES);

    // 7. Initializing community messages
    await upsertCollection(db, 'communityMessages', COMMUNITY_MESSAGE_SCHEMA, COMMUNITY_MESSAGE_INDEXES);

    // 8. Initializing friendships
    await upsertCollection(db, 'friendships', FRIENDSHIP_SCHEMA, FRIENDSHIP_INDEXES);

    // 9. Initializing game matches / ratings / queue
    await upsertCollection(db, 'gameMatches', GAME_MATCH_SCHEMA, GAME_MATCH_INDEXES);
    await upsertCollection(db, 'gameRatings', GAME_RATING_SCHEMA, GAME_RATING_INDEXES);
    await upsertCollection(db, 'gameQueue', GAME_QUEUE_SCHEMA, GAME_QUEUE_INDEXES);

    console.log(" ✅ All collections and indexes initialized.");
}

/**
 * Helper function for atomically creating a collection or updating its validator.
 * @param {import('mongodb').Db} db
 * @param {string} collectionName
 * @param {object} schema
 * @param {Array<object>} indexes
 */
async function upsertCollection(db, collectionName, schema, indexes) {
    // 1. Creating a collection with validation or updating a validator
    try {
        await db.createCollection(collectionName, {
            validator: { $jsonSchema: schema },
            validationAction: 'error', // Block insert/update on error
            validationLevel: 'strict', // Apply to all documents
        });
        console.log(` [${collectionName}] Collection created with $jsonSchema.`);
    } catch (e) {
        if (e.code === 48) {
            // Code 48: Collection already exists. Updating the validator.
            await db.command({
                collMod: collectionName,
                validator: { $jsonSchema: schema },
                validationAction: 'error',
                validationLevel: 'strict',
            });
            console.log(` [${collectionName}] $jsonSchema updated.`);
        } else {
            console.error(` [${collectionName}] Error creating/updating collection:`, e);
            throw e;
        }
    }

    // 2. Creating indexes
    const collection = db.collection(collectionName);
    for (const index of indexes) {
        // createIndex creates an index only if it doesn't already exist (atomically)
        await collection.createIndex(index.key, index.options);
        console.log(` [${collectionName}] Index created: ${JSON.stringify(index.key)}`);
    }
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote backend/src/core/engine/db/initializeCollections.js"

mkdir -p "frontend/src/pages/GamesPage"
cat > "frontend/src/pages/GamesPage/GamesPage.jsx" << 'CRYSTAL_EOF_3E9A1F84'
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

import styles from './GamesPage.module.css';

export const GAMES = [
  { key: 'colorGuess', name: 'Color Guess', emoji: '🎨', description: 'A color is shown — guess its RGB. Closest wins.', available: true },
  { key: 'math', name: 'Math Sprint', emoji: '🔢', description: 'Rapid-fire number puzzles.', available: false },
  { key: 'frequency', name: 'Frequency', emoji: '🔊', description: 'Hear a tone, guess the Hz.', available: false },
  { key: 'wordle', name: 'Wordle Duel', emoji: '🟩', description: 'Race to crack the word.', available: false },
  { key: 'sudoku', name: 'Sudoku', emoji: '🧩', description: 'Solve faster than your rival.', available: false },
  { key: 'zip', name: 'Zip', emoji: '➿', description: 'Connect 1→N through every cell.', available: false }
];

const BOARDS = { colorGuess: ColorGuess };

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
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/GamesPage/GamesPage.jsx"

mkdir -p "frontend/src/pages/GamesPage"
cat > "frontend/src/pages/GamesPage/GamesPage.module.css" << 'CRYSTAL_EOF_3E9A1F84'
.games_page {
  margin-bottom: var(--content_margin_bottom_global);
}

.title {
  position: relative;
  padding: 12px 0;
  background-color: var(--filling_background-color_global);
  border-bottom: var(--border_global);
  border-left: var(--border_disappears_in_dark_theme_global);
  border-right: var(--border_disappears_in_dark_theme_global);
  display: flex;
  align-items: center;
  justify-content: center;
}

.title h1 {
  text-align: center;
  font-family: Arial, Helvetica, sans-serif;
  font-size: 22px;
  line-height: 32px;
  color: var(--color_global);
}

.back_link {
  position: absolute;
  left: 16px;
  font-size: 22px;
  text-decoration: none;
  color: var(--color_global);
}

.forfeit {
  position: absolute;
  right: 16px;
  background: transparent;
  border: var(--border_global);
  color: var(--separator_color_global);
  border-radius: 8px;
  padding: 5px 12px;
  cursor: pointer;
  font-size: 13px;
}

/* ---------- picker ---------- */
.grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
  padding: 16px;
}

.card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 18px;
  border-radius: 14px;
  background-color: var(--filling_background-color_global);
  border: var(--border_global);
  text-decoration: none;
  color: var(--color_global);
  position: relative;
  transition: var(--transition_background-color_hover_global);
}

.card:hover {
  background-color: var(--item_hover_global);
}

.card_soon {
  opacity: 0.55;
  cursor: default;
}

.card_emoji {
  font-size: 30px;
}

.card_name {
  font-weight: 700;
  font-size: 17px;
}

.card_desc {
  font-size: 13px;
  color: var(--separator_color_global);
}

.card_badge {
  position: absolute;
  top: 12px;
  right: 12px;
  font-size: 11px;
  text-transform: uppercase;
  color: var(--separator_color_global);
  border: var(--border_global);
  border-radius: 6px;
  padding: 2px 6px;
}

/* ---------- lobby ---------- */
.section {
  background-color: var(--filling_background-color_global);
  border-bottom: var(--border_global);
  padding: 16px;
}

.section_title {
  font-size: 14px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--separator_color_global);
  margin-bottom: 12px;
}

.rating_row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 14px;
}

.rating_label {
  color: var(--separator_color_global);
}

.rating_value {
  font-size: 26px;
  font-weight: 800;
  color: var(--color_global);
}

.btn_primary_lg {
  width: 100%;
  padding: 14px;
  border: none;
  border-radius: 12px;
  background-color: var(--hashtag_color_global);
  color: #fff;
  font-size: 17px;
  font-weight: 700;
  cursor: pointer;
}

.btn_primary_lg:disabled { opacity: 0.6; cursor: default; }

.searching {
  display: flex;
  align-items: center;
  gap: 14px;
  justify-content: center;
  color: var(--separator_color_global);
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 8px 0;
  border-bottom: var(--border_global);
}

.row:last-child { border-bottom: none; }

.row_user {
  display: flex;
  align-items: center;
  gap: 10px;
  text-decoration: none;
  color: var(--color_global);
  min-width: 0;
}

.row_name {
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.row_actions { display: flex; gap: 8px; flex-shrink: 0; }

.avatar {
  border-radius: 50%;
  object-fit: cover;
  display: block;
  flex-shrink: 0;
}

.avatar_empty {
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: var(--item_hover_global);
}

.avatar_empty svg { width: 60%; height: 60%; fill: var(--fill_no_avatar_global); }

.btn_primary, .btn_secondary, .btn_muted {
  padding: 7px 14px;
  border-radius: 10px;
  border: none;
  cursor: pointer;
  font-size: 14px;
  text-decoration: none;
  white-space: nowrap;
}

.btn_primary { background-color: var(--hashtag_color_global); color: #fff; }
.btn_secondary { background-color: var(--item_hover_global); color: var(--color_global); }
.btn_muted { background-color: transparent; border: var(--border_global); color: var(--separator_color_global); }
.btn_primary:disabled, .btn_secondary:disabled, .btn_muted:disabled { opacity: 0.55; cursor: default; }

.leaderboard { list-style: none; }

.lb_row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 7px 0;
  border-bottom: var(--border_global);
}
.lb_row:last-child { border-bottom: none; }

.lb_rank { width: 22px; text-align: center; font-weight: 700; color: var(--separator_color_global); }
.lb_rating { margin-left: auto; font-weight: 700; }

.empty { color: var(--separator_color_global); padding: 6px 0; }

/* ---------- match result / shared ---------- */
.center_loader { height: 280px; display: flex; align-items: center; justify-content: center; }
.loader { height: 21px; width: 21px; }

.waiting, .result { text-align: center; }
.waiting { color: var(--separator_color_global); padding: 24px 0; }

.result { display: flex; flex-direction: column; align-items: center; gap: 14px; padding: 28px 16px; }

.result_badge {
  font-size: 26px;
  font-weight: 800;
  padding: 6px 20px;
  border-radius: 12px;
}
.result_win { color: #fff; background-color: #2ecc71; }
.result_loss { color: #fff; background-color: #e74c3c; }
.result_draw { color: var(--color_global); background-color: var(--item_hover_global); }

.scoreline { display: flex; gap: 24px; font-size: 17px; }
.elo_delta { color: var(--separator_color_global); }
.result_actions { display: flex; gap: 10px; margin-top: 6px; }
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/GamesPage/GamesPage.module.css"

mkdir -p "frontend/src/pages/GamesPage"
cat > "frontend/src/pages/GamesPage/index.js" << 'CRYSTAL_EOF_3E9A1F84'
export { GamesPage } from "./GamesPage";
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/GamesPage/index.js"

mkdir -p "frontend/src/pages/GamesPage/games"
cat > "frontend/src/pages/GamesPage/games/ColorGuess.jsx" << 'CRYSTAL_EOF_3E9A1F84'
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
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/GamesPage/games/ColorGuess.jsx"

mkdir -p "frontend/src/pages/GamesPage/games"
cat > "frontend/src/pages/GamesPage/games/ColorGuess.module.css" << 'CRYSTAL_EOF_3E9A1F84'
.board {
  background-color: var(--filling_background-color_global);
  padding: 18px 16px 28px;
}

.scoreboard {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 20px;
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

.round_indicator {
  font-weight: 700;
  color: var(--color_global);
}

.swatches {
  display: flex;
  gap: 16px;
  justify-content: center;
}

.swatch_wrap { display: flex; flex-direction: column; align-items: center; gap: 6px; }

.swatch {
  width: 120px;
  height: 120px;
  border-radius: 14px;
  border: var(--border_global);
}

.swatch_label { font-size: 12px; color: var(--separator_color_global); }

.timer {
  text-align: center;
  font-size: 14px;
  color: var(--separator_color_global);
  margin: 12px 0;
}

.sliders {
  max-width: 360px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.slider_row { display: flex; align-items: center; gap: 12px; }

.slider_label {
  width: 18px;
  font-weight: 800;
  text-align: center;
}
.r { color: #e74c3c; }
.g { color: #2ecc71; }
.b { color: #3498db; }

.slider { flex: 1; cursor: pointer; accent-color: var(--hashtag_color_global); }
.slider_r { accent-color: #e74c3c; }
.slider_g { accent-color: #2ecc71; }
.slider_b { accent-color: #3498db; }

.slider_value {
  width: 38px;
  text-align: right;
  font-variant-numeric: tabular-nums;
  color: var(--color_global);
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
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/GamesPage/games/ColorGuess.module.css"

mkdir -p "frontend/src/pages"
cat > "frontend/src/pages/index.js" << 'CRYSTAL_EOF_3E9A1F84'
export { HomePage } from "./HomePage";
export { SearchPage } from "./SearchPage";
export { FullPostPage } from "./FullPostPage";
export { PostCreatePage } from "./PostCreatePage";
export { PostEditPage } from "./PostEditPage";
export { UserProfilePage } from "./UserProfilePage";
export { UserEditPage } from "./UserEditPage";
export { HashtagPage } from "./HashtagPage";
export { LikesPage } from "./LikesPage";
export { MessagesPage } from "./MessagesPage";
export { CommunitiesPage } from "./CommunitiesPage";
export { FriendsPage } from "./FriendsPage";
export { GamesPage } from "./GamesPage";
export { NotFoundPage } from "./NotFoundPage";
export { TermsPage } from "./TermsPage";
export { PrivacyPage } from "./PrivacyPage";
export { CookiesPolicyPage } from "./CookiesPolicyPage";
export { AboutCrystalPage } from "./AboutCrystalPage";
export { AgreementsPage } from "./AgreementsPage";
export { HelpPage } from "./HelpPage";
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/pages/index.js"

mkdir -p "frontend/src/app"
cat > "frontend/src/app/App.jsx" << 'CRYSTAL_EOF_3E9A1F84'
// frontend/src/app/App.jsx
import {
  Routes,
  Route,
  useLocation
} from 'react-router-dom';
import { useSelector } from 'react-redux';
import { useEffect } from 'react';

import { useAuth } from "../features";
import {
  AccessModal,
  MoreAboutUserModal,
  SideMenuMobile,
  SideMenuMobileBackground,
} from '../features';
import { useWebSocket } from '../shared/hooks';
import {
  HomePage,
  SearchPage,
  FullPostPage,
  PostCreatePage,
  PostEditPage,
  UserProfilePage,
  UserEditPage,
  HashtagPage,
  LikesPage,
  MessagesPage,
  CommunitiesPage,
  FriendsPage,
  GamesPage,
  NotFoundPage,
  TermsPage,
  PrivacyPage,
  CookiesPolicyPage,
  AboutCrystalPage,
  AgreementsPage,
  HelpPage
} from '../pages';
import {
  SearchAndSort,
  CookiesBanner,
  UpButton
} from '../shared/ui';
import { HeaderMobile } from '../widgets';
import {
  RightSide,
  LeftSide
} from '../layout';

import styles from './App.module.css';

export default function App() {

  useAuth()

  useWebSocket();

  const location = useLocation()
  const defineFullPostPage = location.pathname.includes('/posts/')

  // dark theme
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  useEffect(() => {
    const html = document.documentElement;
    html.setAttribute('data-dark-theme', String(darkThemeStatus));
  }, [darkThemeStatus]);
  // /dark theme

  return (
    <div className={styles.app}>
      <div className={styles.left_center_right_parts_wrap}>
        <div className={styles.left_center_right_parts}>
          <div className={styles.left_side_wrap}>
            <LeftSide />
          </div>
          <div className={
            defineFullPostPage
              ? `${styles.center} ${styles.center_full}`
              : styles.center
          }>
            <div className={styles.header_mobile_wrap}>
              <HeaderMobile />
              <SideMenuMobile />
            </div>

            <SearchAndSort />

            <Routes>
              <Route path="/" element={<HomePage />} />

              {/* search */}
              <Route path="/search" element={<SearchPage />} />
              {/* /search */}

              {/* users */}
              <Route path="/:userId" element={<UserProfilePage />} />
              <Route path="/users/:userId/edit" element={<UserEditPage />} />
              <Route path="/likes/:userId" element={<LikesPage />} />
              {/* /users */}

              {/* messages */}
              <Route path="/messages" element={<MessagesPage />} />
              <Route path="/messages/:userId" element={<MessagesPage />} />
              {/* /messages */}

              {/* communities */}
              <Route path="/communities" element={<CommunitiesPage />} />
              <Route path="/communities/:communityId" element={<CommunitiesPage />} />
              {/* /communities */}

              {/* friends */}
              <Route path="/friends" element={<FriendsPage />} />
              {/* /friends */}

              {/* games */}
              <Route path="/games" element={<GamesPage />} />
              <Route path="/games/match/:matchId" element={<GamesPage />} />
              <Route path="/games/:gameType" element={<GamesPage />} />
              {/* /games */}

              {/* posts */}
              <Route path="/posts/:postId" element={<FullPostPage />} />
              <Route path="/posts/new" element={<PostCreatePage />} />
              <Route path="/posts/:postId/edit" element={<PostEditPage />} />
              <Route path="/hashtags/:tag" element={<HashtagPage />} />
              {/* /posts */}

              {/* agreements */}
              <Route path="/agreements" element={<AgreementsPage />} />
              <Route path="/terms" element={<TermsPage />} />
              <Route path="/privacy" element={<PrivacyPage />} />
              <Route path="/cookies-policy" element={<CookiesPolicyPage />} />
              {/* /agreements */}

              {/* others */}
              <Route path="/about-crystal" element={<AboutCrystalPage />} />
              <Route path="/help" element={<HelpPage />} />
              {/* /others */}

              {/* 404 */}
              <Route path="*" element={<NotFoundPage />} />
              {/* /404 */}

            </Routes>

          </div>
          <div className={styles.right_side_wrap}>
            <RightSide />
          </div>
        </div>
      </div>
      <CookiesBanner />
      <AccessModal />
      <MoreAboutUserModal />
      <SideMenuMobileBackground />
      <UpButton />
    </div>
  );
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/app/App.jsx"

mkdir -p "frontend/src/widgets/SideMenuDesktop"
cat > "frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx" << 'CRYSTAL_EOF_3E9A1F84'
import { useSelector } from 'react-redux';
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";

import { useAuthData } from "../../features";
import {
  UserIcon,
  SettingsIcon,
  MessagesIcon,
  FriendsIcon,
  GroupsIcon,
  PhotosIcon,
  VideosIcon,
  BookmarkIcon,
  HelpIcon,
  CrystalIcon,
  LikeIcon,
  DocumentationIcon,
} from '../../shared/ui';

import styles from "./SideMenuDesktop.module.css";

export function SideMenuDesktop() {

  const { authorizedUser } = useAuthData();
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);
  const { t } = useTranslation();

  if (!authorizedUser) {
    return null
  }

  return (
    <nav
      className={styles.side_menu_desktop}
      data-side-menu-desktop-dark-theme={darkThemeStatus}
    >
      <ul>
        <li className={styles.user}>
          <UserIcon />
          <p>{t("SideMenuDesktop.MyProfile")}</p>
          <Link to={"/" + authorizedUser.customId}></Link>
        </li>
        
        {/* --- FIXED: Messages Link --- */}
        <li className={styles.messages}>
          <MessagesIcon />
          <p>{t("SideMenuDesktop.Messages")}</p>
          <Link to="/messages"></Link> 
        </li>
        {/* --------------------------- */}

        <li className={styles.friends}>
          <FriendsIcon />
          <p>{t("SideMenuDesktop.Friends")}</p>
          <Link to="/friends"></Link>
        </li>
        <li className={styles.groups}>
          <GroupsIcon />
          <p>{t("SideMenuDesktop.Communities")}</p>
          <Link to="/communities"></Link>
        </li>
        <li className={styles.games}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <rect x="2" y="7" width="20" height="11" rx="5.5" />
            <line x1="7" y1="11" x2="7" y2="14" />
            <line x1="5.5" y1="12.5" x2="8.5" y2="12.5" />
            <circle cx="16" cy="11.5" r="1.1" />
            <circle cx="18.5" cy="14" r="1.1" />
          </svg>
          <p>{t("SideMenuDesktop.Games")}</p>
          <Link to="/games"></Link>
        </li>
        <li className={styles.photo}>
          <PhotosIcon />
          <p>{t("SideMenuDesktop.Photo")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.video}>
          <VideosIcon />
          <p>{t("SideMenuDesktop.Video")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.bookmark}>
          <BookmarkIcon />
          <p>{t("SideMenuDesktop.Bookmarks")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.like}>
          <LikeIcon />
          <p>{t("SideMenuDesktop.Likes")}</p>
          <Link to={"/likes/" + authorizedUser.customId}></Link>
        </li>
        <li className={styles.settings}>
          <SettingsIcon />
          <p>{t("SideMenuDesktop.Settings")}</p>
          <Link to={`/users/${authorizedUser.customId}/edit`}></Link>
        </li>
        <li className={styles.crystal}>
          <CrystalIcon />
          <p>{t("SideMenuDesktop.AboutCrystal")}</p>
          <Link to={"/about-crystal"} target="_blank"></Link>
        </li>
        <li className={styles.agreements}>
          <DocumentationIcon />
          <p>{t("SideMenuDesktop.Agreements")}</p>
          <Link to={"/agreements"} target="_blank"></Link>
        </li>
        <li className={styles.help}>
          <HelpIcon />
          <p>{t("SideMenuDesktop.Help")}</p>
          <Link to={"/help"} target="_blank"></Link>
        </li>
      </ul>
    </nav>
  );
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx"

mkdir -p "frontend/src/widgets/SideMenuDesktop"
cat > "frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.module.css" << 'CRYSTAL_EOF_3E9A1F84'
.side_menu_desktop {
  margin-top: 15px;
  overflow: hidden;
  margin-bottom: 50px;
  border-radius: 15px;
  position: relative;
  /* right: 8px; */
  background-color: var(--filling_background-color_global);
}

.side_menu_desktop ul li {
  gap: 15px;
  padding: 12px 13px;
  cursor: pointer;
  display: flex;
  align-items: center;
  border-radius: var(--side_menu_desktop_ul_li_border-radius);
  font-family: Arial, Helvetica, sans-serif;
  font-size: 19px;
  line-height: 22px;
  font-weight: 400;
  text-wrap: nowrap;
  position: relative;
}

/* .side_menu_desktop ul li:first-child {
  padding: 17px 14px 14px 14px;
}

.side_menu_desktop ul li:last-child {
  padding: 14px 14px 17px 14px;
} */

.side_menu_desktop ul li a {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  right: 0;
}

.help svg {
  width: 24px;
  height: 24px;
  position: relative;
  stroke: var(--stroke_global);
  fill: var(--fill_global);
}

.crystal svg {
  width: 24px;
  height: 24px;
  fill: var(--fill_global);
  stroke: var(--stroke_global);
  stroke-width: 3;
}

.like svg {
  width: 22px;
  height: 22px;
  stroke: var(--stroke_global);
  fill: none;
}

.settings svg {
  width: 24.5px;
  height: 24.5px;
  stroke: var(--stroke_global);
}

.photo svg {
  width: 23px;
  height: 23px;
  fill: var(--fill_global);
}

.video svg {
  stroke: var(--stroke_global);
  width: 24px;
  height: 24px;
  position: relative; 
}

.user svg {
  width: 24px;
  height: 24px;
  position: relative;
  stroke: var(--stroke_global);
}

.messages svg {
  width: 23px;
  height: 23px;
  stroke: var(--stroke_global);
}

.friends svg {
  stroke: var(--stroke_global);
  width: 24px;
  height: 24px;
}

.groups svg {
  width: 24px;
  height: 24px;
  stroke: var(--stroke_global);
}

.bookmark svg {
  stroke: var(--stroke_global);
  width: 24px;
  height: 24px;
}

.agreements svg {
  fill: var(--fill_global);
  width: 22px;
  height: 22px;
}

@media (max-width: 1200px) {
  .side_menu_desktop ul li:active {
    background-color: var(--item_hover_global);
    transition: var(--transition_background-color_hover_global);
  }
}

@media (max-width: 1170px) {

  .side_menu_desktop svg {
    width: 26px;
    height: 26px;
  }

  .side_menu_desktop p {
    display: none;
  }

  .side_menu_desktop ul {
    display: grid;
    gap: var(--side_menu_desktop_ul_gap); 
  }

  .side_menu_desktop ul li {
    padding: var(--side_menu_desktop_ul_li_padding);
  }
}

@media (min-width: 1200px) {
  .side_menu_desktop ul li:hover {
    background-color: var(--item_hover_global);
    transition: var(--transition_background-color_hover_global);
  }
}

/* variables */
/* theme colors */
[data-side-menu-desktop-dark-theme="true"] {
  --side_menu_desktop_ul_li_border-radius: 0px;
  --side_menu_desktop_ul_li_padding: 13px;
  --side_menu_desktop_ul_gap: 0px;
}

[data-side-menu-desktop-dark-theme="false"] {
  --side_menu_desktop_ul_li_border-radius: 22px;
  --side_menu_desktop_ul_li_padding: 10px;
  --side_menu_desktop_ul_gap: 3px;
}

/* /theme colors */
/* /variables */
/* games nav item (added) */
.games svg {
  width: 24px;
  height: 24px;
  stroke: var(--stroke_global);
  fill: none;
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.module.css"

mkdir -p "frontend/src/shared/hooks/useWebSocket"
cat > "frontend/src/shared/hooks/useWebSocket/useWebSocket.js" << 'CRYSTAL_EOF_3E9A1F84'
// frontend/src/shared/hooks/useWebSocket.js

import { useEffect, useRef, useState, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useAuthData } from '../../../features';
import { WS_URL } from '../../../shared/constants';

const generateTabId = () => {
  return (Date.now() + Math.random())
    .toString(36)
    .replace('.', '')
    .substring(2);
};

export function useWebSocket() {
  const queryClient = useQueryClient();
  const { authorizedUser, isSuccess: isAuthSuccess } = useAuthData();
  
  const wsRef = useRef(null);
  const tabIdRef = useRef(generateTabId());
  
  // Trigger for hard reset of connection
  const [reconnectCount, setReconnectCount] = useState(0);
  
  const hiddenTimeoutRef = useRef(null);
  
  // A flag to let you know if we've gone into "long sleep"
  const wasHiddenRef = useRef(false);

  const [wsState, setWsState] = useState({
    isConnected: false,
    isPending: false,
    isError: false,
    isSuccess: false,
  });

  const closeSocket = useCallback((socket, code, reason) => {
    if (socket) {
      socket.onclose = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onopen = null;
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close(code, reason);
      }
    }
  }, []);

  useEffect(() => {
    if (!isAuthSuccess || !authorizedUser?._id) {
      if (wsRef.current) {
        if (wsRef.current.readyState === WebSocket.OPEN) {
          wsRef.current.send(JSON.stringify({
            type: 'logout',
            userId: authorizedUser?._id || 'unknown',
            tabId: tabIdRef.current,
          }));
        }
        closeSocket(wsRef.current, 1000, 'User logged out');
        wsRef.current = null;
      }
      return;
    }

    // We generate a new ID for each new connection.
    tabIdRef.current = generateTabId();
    const currentTabId = tabIdRef.current;
    const userId = authorizedUser._id;

    setWsState(prev => ({ ...prev, isPending: true, isError: false }));

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState({ isConnected: true, isPending: false, isError: false, isSuccess: true });
      wasHiddenRef.current = false; // Reset the "was hidden" flag
      
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'visibility',
          status: 'visible', // Always visible on startup
          userId,
          tabId: currentTabId,
        }));
        ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
      }

      ws.activityInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
          ws.send('ping');
        }
      }, 30000); 
    };

    ws.onmessage = (event) => {
      try {
        if (event.data === 'pong') return;
        const data = JSON.parse(event.data);
        
        //  Change of status 'online', in real time (Optimistic update on socket event) 
        if (data.type === 'user:online' || data.type === 'user:offline') {
          const isOnlineNow = data.type === 'user:online';
          
          // 1. Instantly refresh the cache for THIS specific user
          // It doesn't matter whether we look at this user's profile or the list where he is.
          queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
             if (!oldData || !oldData.data) return oldData;
             
             // If the ID in the cache matches the ID from the socket event
             if (oldData.data._id === data.userId) {
               return {
                 ...oldData,
                 data: {
                   ...oldData.data,
                   status: {
                     ...oldData.data.status,
                     isOnline: isOnlineNow, // Set status instantly
                     // If you're logged in, update lastSeen to "now"
                     lastSeen: isOnlineNow ? new Date().toISOString() : oldData.data.status.lastSeen
                   }
                 }
               };
             }
             return oldData;
          });

          // 2. And only then do we start the background update (for reliability)
          queryClient.invalidateQueries({ queryKey: ['users'] });
        }

        // New direct message -> refresh conversations and the open thread
        if (data.type === 'message:new') {
          queryClient.invalidateQueries({ queryKey: ['messages'] });
        }

        // New community message -> refresh the affected room
        if (data.type === 'community:message') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }

        // Friend request / accept / change -> refresh friends + requests
        if (data.type === 'friend:update') {
          queryClient.invalidateQueries({ queryKey: ['friends'] });
        }

        // Community join request created / approved / declined
        if (data.type === 'community:request') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }

        // Games: matched / challenge / opponent progress / match over
        if (
          data.type === 'game:matched' ||
          data.type === 'game:challenge' ||
          data.type === 'game:update' ||
          data.type === 'game:over'
        ) {
          queryClient.invalidateQueries({ queryKey: ['games'] });
        }
      } catch (error) {
        console.error('[WS] Parse error:', error);
      }
    };

    ws.onclose = (event) => {
      setWsState(prev => ({ ...prev, isConnected: false, isSuccess: false }));
      if (ws.activityInterval) clearInterval(ws.activityInterval);

      // Auto-reconnect if the connection is lost
      if (ws === wsRef.current && isAuthSuccess) {
        setTimeout(() => {
             setReconnectCount(prev => prev + 1); 
        }, 1000);
      }
    };

    ws.onerror = (error) => {
      console.error('[WS] Error:', error);
      setWsState(prev => ({ ...prev, isError: true }));
      ws.close(); 
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        // 🟢 WE'RE BACK!

        // We immediately update the data from the server
        queryClient.invalidateQueries({ queryKey: ['users'] });

        // Optimistic Renewal of Ourselves (So that the light bulb immediately turns on in us)
        queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
           if (!oldData || !oldData.data) return oldData;
           if (oldData.data._id === userId) {
             return { ...oldData, data: { ...oldData.data, status: { ...oldData.data.status, isOnline: true } } };
           }
           return oldData;
        });

        if (hiddenTimeoutRef.current) {
          clearTimeout(hiddenTimeoutRef.current);
          hiddenTimeoutRef.current = null;
          wasHiddenRef.current = false;
          return; 
        }

        // Hard Reconnect After a Long Sleep
        if (wasHiddenRef.current || !ws || ws.readyState !== WebSocket.OPEN) {
           setReconnectCount(c => c + 1);
        } else {
           ws.send(JSON.stringify({ type: 'visibility', status: 'visible', userId, tabId: currentTabId }));
           ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
        }

      } else {
         // 🔴 WE'RE LEAVING
         if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
         
         hiddenTimeoutRef.current = setTimeout(() => {
             wasHiddenRef.current = true; // Let's remember that we have "officially" gone into invisibility.
             if (ws.readyState === WebSocket.OPEN) {
                 ws.send(JSON.stringify({ type: 'visibility', status: 'hidden', userId, tabId: currentTabId }));
             }
             hiddenTimeoutRef.current = null;
         }, 4000); // exit (hidden) in 4 seconds
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);

    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      if (ws.activityInterval) clearInterval(ws.activityInterval);
      if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
      closeSocket(ws, 1000, 'Cleanup/Reconnecting');
    };

  }, [isAuthSuccess, authorizedUser?._id, queryClient, reconnectCount, closeSocket]);

  return {
    isConnected: wsState.isConnected,
    isPending: wsState.isPending,
    isError: wsState.isError,
    isSuccess: wsState.isSuccess,
  };
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/src/shared/hooks/useWebSocket/useWebSocket.js"

mkdir -p "frontend/public/locales/en"
cat > "frontend/public/locales/en/translation.json" << 'CRYSTAL_EOF_3E9A1F84'
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
    "ColorYourGuess": "Your guess"
  }
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/public/locales/en/translation.json"

mkdir -p "frontend/public/locales/ru"
cat > "frontend/public/locales/ru/translation.json" << 'CRYSTAL_EOF_3E9A1F84'
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
    "ColorYourGuess": "Ваша догадка"
  }
}
CRYSTAL_EOF_3E9A1F84
echo "  wrote frontend/public/locales/ru/translation.json"

echo ""
echo "Done. Games framework + Color Guess written."
