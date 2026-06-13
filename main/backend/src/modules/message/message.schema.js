// src/modules/message/message.schema.js

export const MESSAGE_SCHEMA = {
    bsonType: 'object',
    required: ['senderId', 'receiverId', 'text', 'createdAt', 'read'],
    properties: {
        senderId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        receiverId: {
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
        },
        read: {
            bsonType: 'bool',
            description: 'must be a boolean and is required'
        }
    }
};

export const MESSAGE_INDEXES = [
    // Fast lookup of a conversation between two specific users.
    { key: { senderId: 1, receiverId: 1 } },
    // Fast time-ordering of chat history.
    { key: { createdAt: 1 } },
    // Fast unread counting for the receiver.
    { key: { receiverId: 1, read: 1 } }
];
