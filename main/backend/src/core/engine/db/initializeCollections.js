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
