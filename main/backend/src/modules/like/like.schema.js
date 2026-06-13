// src/modules/like/like.schema.js

export const LIKE_SCHEMA = {
    bsonType: "object",
    title: "Like Document Validation",
    required: ["userId", "postId", "postCreatedAt", "createdAt", "updatedAt"], 
    additionalProperties: false,
    properties: {
        _id: { bsonType: "objectId" },
        userId: { 
            bsonType: "objectId",
            description: "The ID of the user who gave the like."
        },
        postId: { 
            bsonType: "objectId",
            description: "The ID of the post that was liked."
        },
        postCreatedAt: {
            bsonType: "date",
            description: "Post creation date (denormalized for sorting)."
        },
        createdAt: { bsonType: "date" },
        updatedAt: { bsonType: "date" },
    },
};

export const LIKE_INDEXES = [
    // 1. Unique index: prevents duplicate likes
    { 
        key: { userId: 1, postId: 1 }, 
        options: { unique: true, name: 'user_post_unique_idx' } 
    },
    // 2. Index for the "User's Liked Posts" page
    { 
        key: { userId: 1, postCreatedAt: -1, postId: 1 }, 
        options: { name: 'user_likes_timeline_idx' } 
    },
    // 3. An index for quickly counting post likes
    { key: { postId: 1 }, name: 'post_likes_count_idx' }, 
];