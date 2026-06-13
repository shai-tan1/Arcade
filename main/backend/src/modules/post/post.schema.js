// src/modules/post/post.schema.js

export const POST_SCHEMA = {
    bsonType: "object",
    title: "Post Document Validation",
    required: ["user", "title", "text", "views", "createdAt", "updatedAt"], 
    additionalProperties: false, // Strict prohibition of unnecessary fields
    properties: {
        _id: {
            bsonType: "objectId"
        },
        user: { 
            bsonType: "objectId",
            description: "Post author ID (link to users._id)"
        },
        title: {
            bsonType: "string",
            description: "Post title.",
        },
        text: {
            bsonType: "string",
            description: "Text of the post.",
        },
        mainImageUri: {
            bsonType: ["string", "null"], 
            description: "URI of the main image."
        },
        views: {
            bsonType: "int",
            description: "Number of views.",
            minimum: 0
        },
        // Timestamps
        createdAt: { bsonType: "date" },
        updatedAt: { bsonType: "date" },
    },
};

// Indexes
export const POST_INDEXES = [
    { key: { createdAt: -1 }, name: 'creation_time_idx' }, 
    { key: { user: 1, createdAt: -1 }, name: 'author_timeline_idx' },
    // 💡 NEW: Text index for post search
    { 
        key: { title: "text", text: "text" }, 
        name: 'post_text_search_idx'
        // Опционально: можно добавить default_language: "russian"
    }
];