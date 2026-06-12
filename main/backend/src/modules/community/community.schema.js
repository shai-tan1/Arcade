// src/modules/community/community.schema.js

export const COMMUNITY_SCHEMA = {
    bsonType: 'object',
    required: ['name', 'creatorId', 'members', 'createdAt'],
    properties: {
        name: {
            bsonType: 'string',
            minLength: 1,
            maxLength: 100,
            description: 'must be a non-empty string and is required'
        },
        description: {
            bsonType: 'string',
            maxLength: 500,
            description: 'optional description'
        },
        avatarUri: {
            bsonType: ['string', 'null'],
            description: 'optional avatar uri'
        },
        isPrivate: {
            bsonType: 'bool',
            description: 'optional; private communities require approval to join'
        },
        creatorId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        members: {
            bsonType: 'array',
            items: { bsonType: 'objectId' },
            description: 'array of member objectIds and is required'
        },
        joinRequests: {
            bsonType: 'array',
            items: { bsonType: 'objectId' },
            description: 'optional; users awaiting approval to join a private community'
        },
        createdAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        }
    }
};

export const COMMUNITY_INDEXES = [
    { key: { name: 1 } },
    { key: { members: 1 } },
    { key: { createdAt: -1 } }
];

export const COMMUNITY_MESSAGE_SCHEMA = {
    bsonType: 'object',
    required: ['communityId', 'senderId', 'text', 'createdAt'],
    properties: {
        communityId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        senderId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        text: {
            bsonType: 'string',
            minLength: 1,
            maxLength: 5000,
            description: 'must be a non-empty string and is required'
        },
        createdAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        }
    }
};

export const COMMUNITY_MESSAGE_INDEXES = [
    { key: { communityId: 1, createdAt: 1 } }
];
