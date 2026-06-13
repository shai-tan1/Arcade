// src/modules/hashtag/hashtag.schema.js

export const HASHTAG_SCHEMA = {
    bsonType: "object",
    title: "Hashtag Document Validation",
    required: ["name", "postId", "postCreatedAt", "createdAt", "updatedAt"], 
    additionalProperties: false, // Strict prohibition of unnecessary fields
    properties: {
        _id: {
            bsonType: "objectId"
        },
         
        name: {
            bsonType: "string",
            description: "Hashtag name (lowercase).",
        },
        
        postId: { 
            bsonType: "objectId",
            description: "Link to the post ID where this hashtag is used."
        },
        
        postCreatedAt: {
            bsonType: "date",
            description: "Post creation date (for sorting/pagination)."
        },
        // Timestamps
        createdAt: { bsonType: "date" },
        updatedAt: { bsonType: "date" },
    },
};

export const HASHTAG_INDEXES = [
    // 1. Compound index for fast searching and cursor pagination
    // (name: 1, postCreatedAt: -1, postId: 1)
    { 
        key: { name: 1, postCreatedAt: -1, postId: 1 }, 
        options: { 
            unique: true, 
            name: 'name_pagination_unique_idx', 
            collation: { locale: 'en', strength: 2 } 
        } 
    }, 
    // 2. To count the total number of posts with a specific hashtag (aggregation)
    { key: { name: 1 }, name: 'name_count_idx' }, 
    
    // 3. To quickly remove all hashtags from a post
    { key: { postId: 1 }, name: 'postId_cleanup_idx' }, 
];