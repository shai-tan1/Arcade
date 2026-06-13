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
