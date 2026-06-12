// src/modules/friend/friend.schema.js

export const FRIENDSHIP_SCHEMA = {
    bsonType: 'object',
    required: ['requesterId', 'recipientId', 'status', 'createdAt', 'updatedAt'],
    properties: {
        requesterId: {
            bsonType: 'objectId',
            description: 'user who sent the request; required'
        },
        recipientId: {
            bsonType: 'objectId',
            description: 'user who received the request; required'
        },
        status: {
            enum: ['pending', 'accepted'],
            description: "must be 'pending' or 'accepted'; required"
        },
        createdAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        },
        updatedAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        }
    }
};

export const FRIENDSHIP_INDEXES = [
    // Fast lookup of a relationship between two users (either direction).
    { key: { requesterId: 1, recipientId: 1 } },
    // Fast lookup of requests/friends a user received.
    { key: { recipientId: 1, status: 1 } },
    // Fast lookup of requests/friends a user sent.
    { key: { requesterId: 1, status: 1 } }
];
