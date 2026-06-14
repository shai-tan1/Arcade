// src/modules/forum/forum.schema.js

export const FORUM_TOPIC_SCHEMA = {
    bsonType: 'object',
    required: ['authorId', 'title', 'body', 'createdAt'],
    properties: {
        authorId: { bsonType: 'objectId' },
        title: { bsonType: 'string' },
        body: { bsonType: 'string' },
        tags: { bsonType: 'array', items: { bsonType: 'string' } },
        visibility: { enum: ['public', 'private'] },
        communityIds: { bsonType: 'array', items: { bsonType: 'objectId' } },
        commentCount: { bsonType: ['int', 'long'] },
        upvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        downvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        createdAt: { bsonType: 'date' },
        updatedAt: { bsonType: 'date' }
    }
};

export const FORUM_TOPIC_INDEXES = [
    { key: { createdAt: -1 } },
    { key: { authorId: 1 } }
];

export const FORUM_COMMENT_SCHEMA = {
    bsonType: 'object',
    required: ['topicId', 'authorId', 'body', 'createdAt'],
    properties: {
        topicId: { bsonType: 'objectId' },
        authorId: { bsonType: 'objectId' },
        parentId: { bsonType: ['objectId', 'null'] },
        body: { bsonType: 'string' },
        deleted: { bsonType: 'bool' },
        upvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        downvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        createdAt: { bsonType: 'date' },
        updatedAt: { bsonType: 'date' }
    }
};

export const FORUM_COMMENT_INDEXES = [
    { key: { topicId: 1, createdAt: 1 } },
    { key: { parentId: 1 } }
];
