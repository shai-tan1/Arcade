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
