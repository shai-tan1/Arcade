#!/usr/bin/env bash
# Forums v2: moderators + public/private (community-scoped) blogs + Arcade rebrand.
#  - Adds an admin module (creator-only moderator management).
#  - Adds isModerator to the user schema; visibility + communityIds to forum topics.
#  - Rewrites the forum controller (visibility filtering + moderator delete powers).
#  - Rewrites ForumsPage (visibility editor, community picker, private badges, mod panel).
#  - Swaps the left-side brand from "Crystal" to "Arcade" with the new logo.
# Idempotent. Requires the base Forums feature already applied. Run from your repo's main/ dir.
set -e
if [ ! -d frontend/src ] || [ ! -d backend/src ]; then echo "ERROR: run from your repo's main/ directory"; exit 1; fi
if [ ! -f frontend/src/pages/ForumsPage/ForumsPage.jsx ]; then echo "ERROR: apply the base forums feature first (apply-forums.sh)"; exit 1; fi

mkdir -p backend/src/modules/admin backend/src/modules/forum frontend/src/pages/ForumsPage frontend/public

cat > backend/src/modules/forum/forum.schema.js << 'XEOF'
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
XEOF
echo "  + backend/src/modules/forum/forum.schema.js"

cat > backend/src/modules/forum/forum.controller.js << 'XEOF'
// src/modules/forum/forum.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const topics = () => getDB().collection('forumTopics');
const comments = () => getDB().collection('forumComments');
const users = () => getDB().collection('users');
const communities = () => getDB().collection('communities');

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1
};

const LIMITS = { title: 200, body: 20000, comment: 10000, tag: 30, tags: 6, page: 30, communities: 20 };

/* ---------------- helpers ---------------- */

function cleanString(v, max) {
    if (typeof v !== 'string') return '';
    return v.trim().slice(0, max);
}

function cleanTags(v) {
    if (!Array.isArray(v)) return [];
    const out = [];
    for (const raw of v) {
        if (typeof raw !== 'string') continue;
        const tag = raw.trim().toLowerCase().slice(0, LIMITS.tag);
        if (tag && !out.includes(tag)) out.push(tag);
        if (out.length >= LIMITS.tags) break;
    }
    return out;
}

// Returns { creator, isModerator } for the requesting user.
async function getActor(myId) {
    const u = await users().findOne({ _id: myId }, { projection: { creator: 1, isModerator: 1 } });
    return { creator: u?.creator === true, isModerator: u?.isModerator === true };
}

function isPrivileged(actor) {
    return actor.creator || actor.isModerator;
}

// ObjectIds of communities the user belongs to.
async function myCommunityIds(myId) {
    const rows = await communities().find({ members: myId }, { projection: { _id: 1 } }).toArray();
    return rows.map((r) => r._id);
}

// Resolve + validate the community selection for a private topic: keep only
// communities the author is actually a member of.
async function resolveCommunities(rawIds, myId) {
    if (!Array.isArray(rawIds)) return [];
    const ids = [];
    for (const raw of rawIds) {
        if (typeof raw === 'string' && ObjectId.isValid(raw)) {
            const oid = new ObjectId(raw);
            if (!ids.some((x) => x.equals(oid))) ids.push(oid);
        }
        if (ids.length >= LIMITS.communities) break;
    }
    if (ids.length === 0) return [];
    const valid = await communities()
        .find({ _id: { $in: ids }, members: myId }, { projection: { _id: 1 } })
        .toArray();
    return valid.map((c) => c._id);
}

function canViewTopic(topic, myId, myComms, privileged) {
    if (privileged) return true;
    if ((topic.visibility || 'public') !== 'private') return true;
    if (topic.authorId && topic.authorId.equals(myId)) return true;
    const comms = topic.communityIds || [];
    return comms.some((c) => myComms.some((m) => m.equals(c)));
}

const authorLookup = {
    $lookup: {
        from: 'users',
        localField: 'authorId',
        foreignField: '_id',
        as: 'author',
        pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
    }
};

function voteFields(myId) {
    return {
        score: {
            $subtract: [
                { $size: { $ifNull: ['$upvoters', []] } },
                { $size: { $ifNull: ['$downvoters', []] } }
            ]
        },
        myVote: {
            $cond: [
                { $in: [myId, { $ifNull: ['$upvoters', []] }] },
                1,
                { $cond: [{ $in: [myId, { $ifNull: ['$downvoters', []] }] }, -1, 0] }
            ]
        }
    };
}

async function applyVote(collection, docId, myId, dir) {
    await collection.updateOne({ _id: docId }, { $pull: { upvoters: myId, downvoters: myId } });
    if (dir === 1) await collection.updateOne({ _id: docId }, { $addToSet: { upvoters: myId } });
    else if (dir === -1) await collection.updateOne({ _id: docId }, { $addToSet: { downvoters: myId } });
    const doc = await collection.findOne({ _id: docId }, { projection: { upvoters: 1, downvoters: 1 } });
    const up = doc?.upvoters || [];
    const down = doc?.downvoters || [];
    return {
        score: up.length - down.length,
        myVote: up.some((u) => u.equals(myId)) ? 1 : down.some((u) => u.equals(myId)) ? -1 : 0
    };
}

/* ---------------- topics ---------------- */

export const listTopics = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const page = Math.max(0, parseInt(req.query.page, 10) || 0);
        const actor = await getActor(myId);
        const priv = isPrivileged(actor);

        const match = priv
            ? {}
            : {
                $or: [
                    { visibility: { $ne: 'private' } },
                    { authorId: myId },
                    { communityIds: { $in: await myCommunityIds(myId) } }
                ]
            };

        const list = await topics().aggregate([
            { $match: match },
            { $sort: { createdAt: -1 } },
            { $skip: page * LIMITS.page },
            { $limit: LIMITS.page },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    title: 1,
                    tags: 1,
                    author: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    visibility: { $ifNull: ['$visibility', 'public'] },
                    commentCount: { $ifNull: ['$commentCount', 0] },
                    snippet: { $substrCP: ['$body', 0, 220] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const createTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const title = cleanString(req.body?.title, LIMITS.title);
        const body = cleanString(req.body?.body, LIMITS.body);
        const tags = cleanTags(req.body?.tags);
        const visibility = req.body?.visibility === 'private' ? 'private' : 'public';
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        let communityIds = [];
        if (visibility === 'private') {
            communityIds = await resolveCommunities(req.body?.communityIds, myId);
            if (communityIds.length === 0) {
                return res.status(400).json({ message: 'Select at least one of your communities for a private blog' });
            }
        }

        const now = new Date();
        const doc = {
            authorId: myId,
            title,
            body,
            tags,
            visibility,
            communityIds,
            commentCount: 0,
            upvoters: [],
            downvoters: [],
            createdAt: now,
            updatedAt: now
        };
        const result = await topics().insertOne(doc);
        res.status(201).json({ topicId: result.insertedId });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });

        const raw = await topics().findOne({ _id: new ObjectId(id) });
        if (!raw) return res.status(404).json({ message: 'Topic not found' });

        const actor = await getActor(myId);
        const priv = isPrivileged(actor);
        const myComms = priv ? [] : await myCommunityIds(myId);
        if (!canViewTopic(raw, myId, myComms, priv)) return res.status(403).json({ message: 'This blog is private' });

        const [topic] = await topics().aggregate([
            { $match: { _id: raw._id } },
            authorLookup,
            { $unwind: '$author' },
            {
                $lookup: {
                    from: 'communities',
                    localField: 'communityIds',
                    foreignField: '_id',
                    as: 'communities',
                    pipeline: [{ $project: { _id: 1, name: 1 } }]
                }
            },
            {
                $project: {
                    title: 1,
                    body: 1,
                    tags: 1,
                    author: 1,
                    authorId: 1,
                    communities: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    visibility: { $ifNull: ['$visibility', 'public'] },
                    commentCount: { $ifNull: ['$commentCount', 0] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();

        topic.isOwner = topic.authorId.equals(myId);
        topic.viewerCanModerate = priv;
        delete topic.authorId;
        res.status(200).json(topic);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const updateTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const topic = await topics().findOne({ _id: new ObjectId(id) });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        if (!topic.authorId.equals(myId)) return res.status(403).json({ message: 'Not allowed' });

        const title = cleanString(req.body?.title, LIMITS.title);
        const body = cleanString(req.body?.body, LIMITS.body);
        const tags = cleanTags(req.body?.tags);
        const visibility = req.body?.visibility === 'private' ? 'private' : 'public';
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        let communityIds = [];
        if (visibility === 'private') {
            communityIds = await resolveCommunities(req.body?.communityIds, myId);
            if (communityIds.length === 0) {
                return res.status(400).json({ message: 'Select at least one of your communities for a private blog' });
            }
        }

        await topics().updateOne(
            { _id: topic._id },
            { $set: { title, body, tags, visibility, communityIds, updatedAt: new Date() } }
        );
        res.status(200).json({ topicId: topic._id });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const deleteTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const topic = await topics().findOne({ _id: new ObjectId(id) });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        const actor = await getActor(myId);
        if (!topic.authorId.equals(myId) && !isPrivileged(actor)) return res.status(403).json({ message: 'Not allowed' });

        await comments().deleteMany({ topicId: topic._id });
        await topics().deleteOne({ _id: topic._id });
        res.status(200).json({ status: 'deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const voteTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const dir = [1, -1, 0].includes(req.body?.dir) ? req.body.dir : 0;
        const topic = await topics().findOne({ _id: new ObjectId(id) });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });

        const actor = await getActor(myId);
        const priv = isPrivileged(actor);
        const myComms = priv ? [] : await myCommunityIds(myId);
        if (!canViewTopic(topic, myId, myComms, priv)) return res.status(403).json({ message: 'This blog is private' });

        const result = await applyVote(topics(), topic._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- comments ---------------- */

async function loadViewableTopic(topicId, myId) {
    const topic = await topics().findOne({ _id: topicId });
    if (!topic) return { error: 404 };
    const actor = await getActor(myId);
    const priv = isPrivileged(actor);
    const myComms = priv ? [] : await myCommunityIds(myId);
    if (!canViewTopic(topic, myId, myComms, priv)) return { error: 403 };
    return { topic, priv };
}

export const listComments = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const { topic, error } = await loadViewableTopic(new ObjectId(id), myId);
        if (error) return res.status(error).json({ message: error === 404 ? 'Topic not found' : 'This blog is private' });

        const list = await comments().aggregate([
            { $match: { topicId: topic._id } },
            { $sort: { createdAt: 1 } },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    parentId: 1,
                    author: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    deleted: { $ifNull: ['$deleted', false] },
                    body: { $cond: [{ $eq: ['$deleted', true] }, '', '$body'] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const createComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const body = cleanString(req.body?.body, LIMITS.comment);
        if (!body) return res.status(400).json({ message: 'A comment cannot be empty' });

        const { topic, error } = await loadViewableTopic(new ObjectId(id), myId);
        if (error) return res.status(error).json({ message: error === 404 ? 'Topic not found' : 'This blog is private' });

        let parentId = null;
        if (req.body?.parentId) {
            if (!ObjectId.isValid(req.body.parentId)) return res.status(400).json({ message: 'Invalid parent id' });
            const parent = await comments().findOne({ _id: new ObjectId(req.body.parentId) });
            if (!parent || !parent.topicId.equals(topic._id)) return res.status(400).json({ message: 'Invalid parent comment' });
            parentId = parent._id;
        }

        const now = new Date();
        const doc = {
            topicId: topic._id,
            authorId: myId,
            parentId,
            body,
            deleted: false,
            upvoters: [],
            downvoters: [],
            createdAt: now,
            updatedAt: now
        };
        const result = await comments().insertOne(doc);
        await topics().updateOne({ _id: topic._id }, { $inc: { commentCount: 1 } });

        const author = await users().findOne({ _id: myId }, { projection: USER_PUBLIC_PROJECTION });
        res.status(201).json({
            _id: result.insertedId,
            parentId,
            author,
            body,
            deleted: false,
            score: 0,
            myVote: 0,
            createdAt: now,
            updatedAt: now
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const updateComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const comment = await comments().findOne({ _id: new ObjectId(commentId) });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        if (comment.deleted) return res.status(400).json({ message: 'Comment was deleted' });
        if (!comment.authorId.equals(myId)) return res.status(403).json({ message: 'Not allowed' });

        const body = cleanString(req.body?.body, LIMITS.comment);
        if (!body) return res.status(400).json({ message: 'A comment cannot be empty' });

        await comments().updateOne({ _id: comment._id }, { $set: { body, updatedAt: new Date() } });
        res.status(200).json({ status: 'updated' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const deleteComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const comment = await comments().findOne({ _id: new ObjectId(commentId) });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        const actor = await getActor(myId);
        if (!comment.authorId.equals(myId) && !isPrivileged(actor)) return res.status(403).json({ message: 'Not allowed' });
        if (comment.deleted) return res.status(200).json({ status: 'deleted' });

        await comments().updateOne({ _id: comment._id }, { $set: { deleted: true, body: '', updatedAt: new Date() } });
        await topics().updateOne({ _id: comment.topicId }, { $inc: { commentCount: -1 } });
        res.status(200).json({ status: 'deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const voteComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const dir = [1, -1, 0].includes(req.body?.dir) ? req.body.dir : 0;
        const comment = await comments().findOne({ _id: new ObjectId(commentId) }, { projection: { _id: 1, deleted: 1, topicId: 1 } });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        if (comment.deleted) return res.status(400).json({ message: 'Comment was deleted' });

        const { error } = await loadViewableTopic(comment.topicId, myId);
        if (error) return res.status(error).json({ message: error === 404 ? 'Topic not found' : 'This blog is private' });

        const result = await applyVote(comments(), comment._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};
XEOF
echo "  + backend/src/modules/forum/forum.controller.js"

cat > backend/src/modules/admin/admin.controller.js << 'XEOF'
// src/modules/admin/admin.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const users = () => getDB().collection('users');

const MOD_PROJECTION = { _id: 1, name: 1, customId: 1, avatarUri: 1, creator: 1, isModerator: 1 };

async function flags(myId) {
    const u = await users().findOne({ _id: myId }, { projection: { creator: 1, isModerator: 1 } });
    return { isCreator: u?.creator === true, isModerator: u?.isModerator === true };
}

// GET /admin/me — any signed-in user; reveals their own privilege level.
export const getMe = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        res.status(200).json(await flags(myId));
    } catch (error) {
        handleServerError(res, error);
    }
};

// GET /admin/moderators — creator only.
export const listModerators = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });
        const list = await users().find({ isModerator: true }).project(MOD_PROJECTION).sort({ name: 1 }).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

// POST /admin/moderators  { customId } — creator only.
export const addModerator = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });

        const customId = typeof req.body?.customId === 'string' ? req.body.customId.trim() : '';
        if (!customId) return res.status(400).json({ message: 'A member username is required' });

        const target = await users().findOne(
            { customId },
            { projection: MOD_PROJECTION, collation: { locale: 'en', strength: 2 } }
        );
        if (!target) return res.status(404).json({ message: 'No member found with that username' });
        if (target.creator) return res.status(400).json({ message: 'The creator already has full access' });
        if (target.isModerator) return res.status(400).json({ message: 'That member is already a moderator' });

        await users().updateOne({ _id: target._id }, { $set: { isModerator: true } });
        res.status(200).json({ ...target, isModerator: true });
    } catch (error) {
        handleServerError(res, error);
    }
};

// DELETE /admin/moderators/:userId — creator only.
export const removeModerator = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });
        const { userId } = req.params;
        if (!ObjectId.isValid(userId)) return res.status(400).json({ message: 'Invalid user id' });
        await users().updateOne({ _id: new ObjectId(userId) }, { $set: { isModerator: false } });
        res.status(200).json({ status: 'removed' });
    } catch (error) {
        handleServerError(res, error);
    }
};
XEOF
echo "  + backend/src/modules/admin/admin.controller.js"

cat > backend/src/modules/admin/admin.routes.js << 'XEOF'
// src/modules/admin/admin.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import * as controller from './admin.controller.js';

const router = express.Router();

router.get('/me', auth, controller.getMe);
router.get('/moderators', auth, controller.listModerators);
router.post('/moderators', auth, controller.addModerator);
router.delete('/moderators/:userId', auth, controller.removeModerator);

export default router;
XEOF
echo "  + backend/src/modules/admin/admin.routes.js"

cat > frontend/src/pages/ForumsPage/ForumsPage.jsx << 'XEOF'
// frontend/src/pages/ForumsPage/ForumsPage.jsx

import { useState, useEffect } from 'react';
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon } from '../../shared/ui';

import styles from './ForumsPage.module.css';

/* ----------------------------- helpers ----------------------------- */
function timeAgo(d) {
  const s = Math.floor((Date.now() - new Date(d).getTime()) / 1000);
  if (s < 60) return `${Math.max(s, 0)}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const days = Math.floor(h / 24);
  if (days < 30) return `${days}d`;
  const mo = Math.floor(days / 30);
  if (mo < 12) return `${mo}mo`;
  return `${Math.floor(mo / 12)}y`;
}

function buildTree(list) {
  const byId = {};
  const roots = [];
  list.forEach((c) => { byId[c._id] = { ...c, children: [] }; });
  list.forEach((c) => {
    const node = byId[c._id];
    if (c.parentId && byId[c.parentId]) byId[c.parentId].children.push(node);
    else roots.push(node);
  });
  return roots;
}

function Avatar({ user, size = 22 }) {
  const style = { width: size, height: size };
  if (user?.avatarUri) {
    return <img className={styles.avatar} style={style} src={(/^https?:\/\//.test(user.avatarUri) ? user.avatarUri : API_BASE_URL + user.avatarUri)} alt={user.name} />;
  }
  return <span className={`${styles.avatar} ${styles.avatar_empty}`} style={style}><NoAvatarIcon /></span>;
}

function LockIcon() {
  return (
    <svg className={styles.lock} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="5" y="11" width="14" height="9" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </svg>
  );
}

function VoteBox({ score, myVote, onVote }) {
  return (
    <div className={styles.vote}>
      <button className={`${styles.varrow} ${myVote === 1 ? styles.up_on : ''}`} onClick={() => onVote(myVote === 1 ? 0 : 1)} aria-label="upvote">▲</button>
      <span className={`${styles.vscore} ${score > 0 ? styles.vpos : score < 0 ? styles.vneg : ''}`}>{score}</span>
      <button className={`${styles.varrow} ${myVote === -1 ? styles.down_on : ''}`} onClick={() => onVote(myVote === -1 ? 0 : -1)} aria-label="downvote">▼</button>
    </div>
  );
}

/* ----------------------------- list ----------------------------- */
function TopicList() {
  const { t } = useTranslation();
  const q = useQuery({ queryKey: ['forums', 'list'], queryFn: () => httpClient.get('/forums'), retry: false });
  const meQ = useQuery({ queryKey: ['admin', 'me'], queryFn: () => httpClient.get('/admin/me'), retry: false });

  return (
    <div className={styles.wrap}>
      <header className={styles.head}>
        <div>
          <h1 className={styles.h1}>{t('ForumsPage.Title')}</h1>
          <p className={styles.sub}>{t('ForumsPage.Subtitle')}</p>
        </div>
        <div className={styles.head_actions}>
          {meQ.data?.isCreator && <Link to="/forums/moderators" className={styles.btn_muted}>{t('ForumsPage.Moderators')}</Link>}
          <Link to="/forums/new" className={styles.btn_primary}>{t('ForumsPage.NewTopic')}</Link>
        </div>
      </header>

      {q.isPending && <div className={styles.center}><div className={styles.loader}><Loader /></div></div>}
      {q.data?.length === 0 && <p className={styles.empty}>{t('ForumsPage.NoTopics')}</p>}

      <ul className={styles.topics}>
        {q.data?.map((tp) => (
          <li key={tp._id} className={styles.topic}>
            <span className={`${styles.listscore} ${tp.score > 0 ? styles.vpos : tp.score < 0 ? styles.vneg : ''}`}>{tp.score}</span>
            <div className={styles.topic_main}>
              <Link to={`/forums/${tp._id}`} className={styles.topic_title}>
                {tp.visibility === 'private' && <LockIcon />}
                {tp.title}
              </Link>
              <p className={styles.topic_snip}>{tp.snippet}{tp.snippet && tp.snippet.length >= 220 ? '…' : ''}</p>
              <div className={styles.meta}>
                <Avatar user={tp.author} size={22} />
                <Link to={`/${tp.author?.customId}`} className={styles.meta_name}>{tp.author?.name}</Link>
                <span className={styles.dot}>·</span><span>{timeAgo(tp.createdAt)}</span>
                <span className={styles.dot}>·</span><span>{tp.commentCount} {t('ForumsPage.CommentsShort')}</span>
                {tp.tags?.map((tag) => <span key={tag} className={styles.tag}>{tag}</span>)}
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* ----------------------------- editor ----------------------------- */
function TopicEditor({ topicId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const editing = !!topicId;
  const existing = useQuery({
    queryKey: ['forums', 'topic', topicId],
    queryFn: () => httpClient.get(`/forums/topic/${topicId}`),
    enabled: editing,
    retry: false
  });
  const communitiesQ = useQuery({ queryKey: ['communities', 'mine'], queryFn: () => httpClient.get('/communities'), retry: false });
  const myComms = (communitiesQ.data || []).filter((c) => c.isMember);

  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [tags, setTags] = useState('');
  const [visibility, setVisibility] = useState('public');
  const [selected, setSelected] = useState([]);

  useEffect(() => {
    if (editing && existing.data) {
      setTitle(existing.data.title || '');
      setBody(existing.data.body || '');
      setTags((existing.data.tags || []).join(', '));
      setVisibility(existing.data.visibility || 'public');
      setSelected((existing.data.communities || []).map((c) => c._id));
    }
  }, [editing, existing.data]);

  const save = useMutation({
    mutationFn: () => {
      const payload = {
        title,
        body,
        tags: tags.split(',').map((s) => s.trim()).filter(Boolean),
        visibility,
        communityIds: visibility === 'private' ? selected : []
      };
      return editing ? httpClient.patch(`/forums/topic/${topicId}`, payload) : httpClient.post('/forums', payload);
    },
    onSuccess: (data) => {
      qc.invalidateQueries({ queryKey: ['forums'] });
      navigate(`/forums/${data.topicId}`);
    }
  });

  const canSave = title.trim() && body.trim() && (visibility === 'public' || selected.length > 0) && !save.isPending;

  return (
    <div className={styles.wrap}>
      <header className={styles.head_simple}>
        <Link to={editing ? `/forums/${topicId}` : '/forums'} className={styles.back}>←</Link>
        <h1 className={styles.h1}>{editing ? t('ForumsPage.EditTopic') : t('ForumsPage.NewTopic')}</h1>
      </header>

      <div className={styles.form}>
        <label className={styles.label}>{t('ForumsPage.TitleField')}</label>
        <input className={styles.input} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} placeholder={t('ForumsPage.TitlePlaceholder')} />

        <label className={styles.label}>{t('ForumsPage.BodyField')}</label>
        <textarea className={styles.textarea} value={body} onChange={(e) => setBody(e.target.value)} rows={12} placeholder={t('ForumsPage.BodyPlaceholder')} />

        <label className={styles.label}>{t('ForumsPage.TagsField')}</label>
        <input className={styles.input} value={tags} onChange={(e) => setTags(e.target.value)} placeholder={t('ForumsPage.TagsPlaceholder')} />

        <label className={styles.label}>{t('ForumsPage.Visibility')}</label>
        <div className={styles.seg}>
          <button type="button" className={`${styles.seg_btn} ${visibility === 'public' ? styles.seg_on : ''}`} onClick={() => setVisibility('public')}>{t('ForumsPage.Public')}</button>
          <button type="button" className={`${styles.seg_btn} ${visibility === 'private' ? styles.seg_on : ''}`} onClick={() => setVisibility('private')}>{t('ForumsPage.Private')}</button>
        </div>

        {visibility === 'private' && (
          <>
            <label className={styles.label}>{t('ForumsPage.SelectCommunities')}</label>
            {myComms.length === 0 ? (
              <p className={styles.hint}>{t('ForumsPage.NoCommunities')}</p>
            ) : (
              <div className={styles.comm_list}>
                {myComms.map((c) => {
                  const on = selected.includes(c._id);
                  return (
                    <button type="button" key={c._id} className={`${styles.comm_chip} ${on ? styles.comm_chip_on : ''}`}
                      onClick={() => setSelected(on ? selected.filter((x) => x !== c._id) : [...selected, c._id])}>
                      {c.name}
                    </button>
                  );
                })}
              </div>
            )}
          </>
        )}

        {save.isError && <p className={styles.error}>{save.error?.message || t('ForumsPage.SaveError')}</p>}

        <div className={styles.form_actions}>
          <button className={styles.btn_primary} disabled={!canSave} onClick={() => save.mutate()}>
            {editing ? t('ForumsPage.Save') : t('ForumsPage.Publish')}
          </button>
          <Link to={editing ? `/forums/${topicId}` : '/forums'} className={styles.btn_muted}>{t('ForumsPage.Cancel')}</Link>
        </div>
      </div>
    </div>
  );
}

/* ----------------------------- comment node ----------------------------- */
function CommentNode({ node, myId, canModerate, t, ctx }) {
  const [replyText, setReplyText] = useState('');
  const [editText, setEditText] = useState(node.body);
  const isReplying = ctx.replyTo === node._id;
  const isEditing = ctx.editing === node._id;
  const mine = !node.deleted && node.author?._id === myId;
  const canDelete = !node.deleted && (mine || canModerate);

  return (
    <div className={styles.cnode}>
      <div className={styles.comment}>
        {node.deleted
          ? <div className={styles.vote}><span className={styles.vscore}>·</span></div>
          : <VoteBox score={node.score} myVote={node.myVote} onVote={(d) => ctx.onVote(node._id, d)} />}
        <div className={styles.comment_main}>
          {node.deleted ? (
            <p className={styles.deleted}>{t('ForumsPage.DeletedComment')}</p>
          ) : (
            <>
              <div className={styles.meta}>
                <Avatar user={node.author} size={20} />
                <Link to={`/${node.author?.customId}`} className={styles.meta_name}>{node.author?.name}</Link>
                <span className={styles.dot}>·</span><span>{timeAgo(node.createdAt)}</span>
              </div>

              {isEditing ? (
                <div className={styles.box}>
                  <textarea className={styles.textarea} rows={3} value={editText} onChange={(e) => setEditText(e.target.value)} />
                  <div className={styles.form_actions}>
                    <button className={styles.btn_primary} disabled={!editText.trim() || ctx.busy} onClick={() => ctx.onEdit(node._id, editText)}>{t('ForumsPage.Save')}</button>
                    <button className={styles.btn_muted} onClick={() => ctx.setEditing(null)}>{t('ForumsPage.Cancel')}</button>
                  </div>
                </div>
              ) : (
                <p className={styles.comment_body}>{node.body}</p>
              )}

              {!isEditing && (
                <div className={styles.comment_actions}>
                  <button className={styles.link_action} onClick={() => { ctx.setReplyTo(isReplying ? null : node._id); setReplyText(''); }}>{t('ForumsPage.Reply')}</button>
                  {mine && <button className={styles.link_action} onClick={() => { ctx.setEditing(node._id); setEditText(node.body); }}>{t('ForumsPage.Edit')}</button>}
                  {canDelete && <button className={styles.link_action} onClick={() => { if (window.confirm(t('ForumsPage.ConfirmDeleteComment'))) ctx.onDelete(node._id); }}>{t('ForumsPage.Delete')}</button>}
                </div>
              )}
            </>
          )}

          {isReplying && !node.deleted && (
            <div className={styles.box}>
              <textarea className={styles.textarea} rows={3} value={replyText} onChange={(e) => setReplyText(e.target.value)} placeholder={t('ForumsPage.WriteReply')} />
              <div className={styles.form_actions}>
                <button className={styles.btn_primary} disabled={!replyText.trim() || ctx.busy} onClick={() => ctx.onReply(node._id, replyText)}>{t('ForumsPage.Reply')}</button>
                <button className={styles.btn_muted} onClick={() => ctx.setReplyTo(null)}>{t('ForumsPage.Cancel')}</button>
              </div>
            </div>
          )}
        </div>
      </div>

      {node.children?.length > 0 && (
        <div className={styles.children}>
          {node.children.map((child) => (
            <CommentNode key={child._id} node={child} myId={myId} canModerate={canModerate} t={t} ctx={ctx} />
          ))}
        </div>
      )}
    </div>
  );
}

/* ----------------------------- topic view ----------------------------- */
function TopicView({ topicId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { authorizedUser } = useAuthData();
  const myId = authorizedUser?._id;

  const topicQ = useQuery({ queryKey: ['forums', 'topic', topicId], queryFn: () => httpClient.get(`/forums/topic/${topicId}`), retry: false });
  const commentsQ = useQuery({ queryKey: ['forums', 'comments', topicId], queryFn: () => httpClient.get(`/forums/topic/${topicId}/comments`), retry: false });

  const [replyTo, setReplyTo] = useState(null);
  const [editing, setEditing] = useState(null);
  const [topComment, setTopComment] = useState('');

  const refreshComments = () => qc.invalidateQueries({ queryKey: ['forums', 'comments', topicId] });
  const refreshTopic = () => qc.invalidateQueries({ queryKey: ['forums', 'topic', topicId] });

  const voteTopic = useMutation({ mutationFn: (dir) => httpClient.post(`/forums/topic/${topicId}/vote`, { dir }), onSuccess: refreshTopic });
  const delTopic = useMutation({ mutationFn: () => httpClient.delete(`/forums/topic/${topicId}`), onSuccess: () => { qc.invalidateQueries({ queryKey: ['forums'] }); navigate('/forums'); } });
  const addComment = useMutation({ mutationFn: ({ body, parentId }) => httpClient.post(`/forums/topic/${topicId}/comments`, { body, parentId }), onSuccess: () => { setReplyTo(null); setTopComment(''); refreshComments(); refreshTopic(); } });
  const editComment = useMutation({ mutationFn: ({ commentId, body }) => httpClient.patch(`/forums/comment/${commentId}`, { body }), onSuccess: () => { setEditing(null); refreshComments(); } });
  const delComment = useMutation({ mutationFn: (commentId) => httpClient.delete(`/forums/comment/${commentId}`), onSuccess: () => { refreshComments(); refreshTopic(); } });
  const voteComment = useMutation({ mutationFn: ({ commentId, dir }) => httpClient.post(`/forums/comment/${commentId}/vote`, { dir }), onSuccess: refreshComments });

  if (topicQ.isPending) return <div className={styles.center}><div className={styles.loader}><Loader /></div></div>;
  if (topicQ.isError) {
    return (
      <div className={styles.wrap}>
        <header className={styles.head_simple}><Link to="/forums" className={styles.back}>←</Link><h1 className={styles.h1}>{t('ForumsPage.Title')}</h1></header>
        <p className={styles.empty}>{t('ForumsPage.TopicError')}</p>
      </div>
    );
  }

  const topic = topicQ.data;
  const tree = buildTree(commentsQ.data || []);
  const ctx = {
    replyTo, setReplyTo, editing, setEditing,
    onVote: (commentId, dir) => voteComment.mutate({ commentId, dir }),
    onReply: (parentId, body) => addComment.mutate({ body, parentId }),
    onEdit: (commentId, body) => editComment.mutate({ commentId, body }),
    onDelete: (commentId) => delComment.mutate(commentId),
    busy: addComment.isPending || editComment.isPending
  };

  return (
    <div className={styles.wrap}>
      <header className={styles.head_simple}><Link to="/forums" className={styles.back}>←</Link><h1 className={styles.h1}>{t('ForumsPage.Title')}</h1></header>

      <article className={styles.post}>
        <VoteBox score={topic.score} myVote={topic.myVote} onVote={(d) => voteTopic.mutate(d)} />
        <div className={styles.post_main}>
          {topic.visibility === 'private' && (
            <div className={styles.priv_badge}>
              <LockIcon />
              <span>{t('ForumsPage.Private')}</span>
              {topic.communities?.length > 0 && <span className={styles.priv_comms}>· {topic.communities.map((c) => c.name).join(', ')}</span>}
            </div>
          )}
          <h2 className={styles.post_title}>{topic.title}</h2>
          <div className={styles.meta}>
            <Avatar user={topic.author} size={24} />
            <Link to={`/${topic.author?.customId}`} className={styles.meta_name}>{topic.author?.name}</Link>
            <span className={styles.dot}>·</span><span>{timeAgo(topic.createdAt)}</span>
            {topic.updatedAt && topic.updatedAt !== topic.createdAt && <><span className={styles.dot}>·</span><span>{t('ForumsPage.Edited')}</span></>}
          </div>
          {topic.tags?.length > 0 && <div className={styles.tags}>{topic.tags.map((tag) => <span key={tag} className={styles.tag}>{tag}</span>)}</div>}
          <div className={styles.post_body}>{topic.body}</div>
          {(topic.isOwner || topic.canModerate) && (
            <div className={styles.owner_actions}>
              {topic.isOwner && <Link to={`/forums/${topicId}/edit`} className={styles.link_action}>{t('ForumsPage.Edit')}</Link>}
              <button className={styles.link_action} onClick={() => { if (window.confirm(t('ForumsPage.ConfirmDeleteTopic'))) delTopic.mutate(); }}>{t('ForumsPage.Delete')}</button>
            </div>
          )}
        </div>
      </article>

      <section className={styles.comments_section}>
        <h3 className={styles.comments_head}>{topic.commentCount} {t('ForumsPage.Comments')}</h3>

        <div className={styles.box}>
          <textarea className={styles.textarea} rows={3} value={topComment} onChange={(e) => setTopComment(e.target.value)} placeholder={t('ForumsPage.WriteComment')} />
          <div className={styles.form_actions}>
            <button className={styles.btn_primary} disabled={!topComment.trim() || addComment.isPending} onClick={() => addComment.mutate({ body: topComment, parentId: null })}>{t('ForumsPage.Comment')}</button>
          </div>
        </div>

        {commentsQ.isPending && <div className={styles.center}><div className={styles.loader}><Loader /></div></div>}
        <div className={styles.tree}>
          {tree.map((node) => <CommentNode key={node._id} node={node} myId={myId} canModerate={!!topic.canModerate} t={t} ctx={ctx} />)}
        </div>
      </section>
    </div>
  );
}

/* ----------------------------- moderators (creator only) ----------------------------- */
function ModeratorsPanel() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const meQ = useQuery({ queryKey: ['admin', 'me'], queryFn: () => httpClient.get('/admin/me'), retry: false });
  const isCreator = meQ.data?.isCreator;
  const modsQ = useQuery({ queryKey: ['admin', 'moderators'], queryFn: () => httpClient.get('/admin/moderators'), enabled: !!isCreator, retry: false });
  const [cid, setCid] = useState('');

  const add = useMutation({
    mutationFn: () => httpClient.post('/admin/moderators', { customId: cid.replace(/^@/, '').trim() }),
    onSuccess: () => { setCid(''); qc.invalidateQueries({ queryKey: ['admin', 'moderators'] }); }
  });
  const remove = useMutation({
    mutationFn: (uid) => httpClient.delete(`/admin/moderators/${uid}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['admin', 'moderators'] })
  });

  if (meQ.isPending) return <div className={styles.center}><div className={styles.loader}><Loader /></div></div>;

  return (
    <div className={styles.wrap}>
      <header className={styles.head_simple}>
        <Link to="/forums" className={styles.back}>←</Link>
        <h1 className={styles.h1}>{t('ForumsPage.Moderators')}</h1>
      </header>

      {!isCreator ? (
        <p className={styles.empty}>{t('ForumsPage.NotAllowed')}</p>
      ) : (
        <>
          <p className={styles.sub}>{t('ForumsPage.ModeratorsHint')}</p>
          <div className={styles.mod_add}>
            <input className={styles.input} value={cid} onChange={(e) => setCid(e.target.value)} placeholder={t('ForumsPage.ModeratorCustomId')} />
            <button className={styles.btn_primary} disabled={!cid.trim() || add.isPending} onClick={() => add.mutate()}>{t('ForumsPage.AddModerator')}</button>
          </div>
          {add.isError && <p className={styles.error}>{add.error?.message || t('ForumsPage.SaveError')}</p>}

          {modsQ.data?.length === 0 && <p className={styles.empty}>{t('ForumsPage.NoModerators')}</p>}
          <ul className={styles.mods}>
            {modsQ.data?.map((m) => (
              <li key={m._id} className={styles.mod_row}>
                <Avatar user={m} size={34} />
                <div className={styles.mod_id}>
                  <Link to={`/${m.customId}`} className={styles.meta_name}>{m.name}</Link>
                  <span className={styles.mod_handle}>@{m.customId}</span>
                </div>
                <button className={styles.link_action} onClick={() => { if (window.confirm(t('ForumsPage.ConfirmRemoveMod'))) remove.mutate(m._id); }}>{t('ForumsPage.RemoveModerator')}</button>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

/* ----------------------------- page ----------------------------- */
export function ForumsPage() {
  const { topicId } = useParams();
  const loc = useLocation();
  if (loc.pathname === '/forums/moderators') return <ModeratorsPanel />;
  if (loc.pathname === '/forums/new') return <TopicEditor />;
  if (topicId && loc.pathname.endsWith('/edit')) return <TopicEditor topicId={topicId} />;
  if (topicId) return <TopicView topicId={topicId} />;
  return <TopicList />;
}
XEOF
echo "  + frontend/src/pages/ForumsPage/ForumsPage.jsx"

cat > frontend/src/pages/ForumsPage/ForumsPage.module.css << 'XEOF'
.wrap { margin-bottom: var(--content_margin_bottom_global); padding: 4px 14px 0; }

/* headers */
.head { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; padding: 14px 4px 18px; }
.h1 { font-size: 28px; font-weight: 800; letter-spacing: -0.02em; color: var(--color_global); }
.sub { margin-top: 6px; font-size: 14px; color: var(--separator_color_global); }
.head_simple { position: relative; display: flex; align-items: center; gap: 12px; padding: 14px 0 18px; }
.back { font-size: 22px; text-decoration: none; color: var(--color_global); }

/* buttons */
.btn_primary, .btn_muted {
  display: inline-flex; align-items: center; justify-content: center;
  padding: 10px 18px; border-radius: 11px; border: none; cursor: pointer;
  font-size: 14px; font-weight: 700; text-decoration: none; white-space: nowrap;
}
.btn_primary { background-color: var(--hashtag_color_global); color: var(--on_accent_global); }
.btn_primary:hover { background-color: var(--hashtag_color_hover_global); }
.btn_primary:disabled { opacity: 0.55; cursor: default; }
.btn_muted { background-color: transparent; border: var(--border_global); color: var(--separator_color_global); }

.center { height: 200px; display: flex; align-items: center; justify-content: center; }
.loader { width: 21px; height: 21px; }
.empty { color: var(--separator_color_global); padding: 18px 4px; }

/* topic list */
.topics { list-style: none; display: flex; flex-direction: column; gap: 10px; }
.topic { display: flex; gap: 14px; padding: 16px; border-radius: 14px; background-color: var(--filling_background-color_global); border: var(--border_global); }
.listscore { min-width: 34px; text-align: center; font-weight: 800; font-size: 16px; color: var(--separator_color_global); align-self: center; }
.topic_main { min-width: 0; flex: 1; }
.topic_title { font-size: 17px; font-weight: 700; color: var(--color_global); text-decoration: none; }
.topic_title:hover { color: var(--hashtag_color_global); }
.topic_snip { margin-top: 5px; font-size: 14px; line-height: 1.45; color: var(--separator_color_global); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

/* meta line */
.meta { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; margin-top: 9px; font-size: 13px; color: var(--separator_color_global); }
.meta_name { color: var(--color_global); font-weight: 600; text-decoration: none; }
.meta_name:hover { color: var(--hashtag_color_global); }
.dot { opacity: 0.6; }
.tags { display: flex; flex-wrap: wrap; gap: 6px; margin: 12px 0; }
.tag { font-size: 12px; font-weight: 600; color: var(--hashtag_color_global); background-color: color-mix(in srgb, var(--hashtag_color_global) 12%, transparent); border-radius: 7px; padding: 3px 9px; }

/* vote box */
.vote { display: flex; flex-direction: column; align-items: center; gap: 2px; min-width: 34px; }
.varrow { background: none; border: none; cursor: pointer; font-size: 13px; line-height: 1; color: var(--separator_color_global); padding: 2px; }
.varrow:hover { color: var(--color_global); }
.up_on { color: var(--hashtag_color_global); }
.down_on { color: #e24b4a; }
.vscore { font-weight: 800; font-size: 15px; color: var(--color_global); }
.vpos { color: var(--hashtag_color_global); }
.vneg { color: #e24b4a; }

/* topic post */
.post { display: flex; gap: 14px; padding: 20px; border-radius: 16px; background-color: var(--filling_background-color_global); border: var(--border_global); }
.post_main { min-width: 0; flex: 1; }
.post_title { font-size: 23px; font-weight: 800; letter-spacing: -0.01em; color: var(--color_global); }
.post_body { margin-top: 14px; font-size: 15px; line-height: 1.6; color: var(--color_global); white-space: pre-wrap; word-break: break-word; }
.owner_actions { display: flex; gap: 14px; margin-top: 16px; }
.link_action { background: none; border: none; cursor: pointer; font-size: 13px; font-weight: 600; color: var(--separator_color_global); padding: 0; text-decoration: none; }
.link_action:hover { color: var(--hashtag_color_global); }

/* comments */
.comments_section { margin-top: 22px; }
.comments_head { font-size: 16px; font-weight: 800; color: var(--color_global); margin-bottom: 14px; }
.box { margin: 10px 0 4px; }
.tree { margin-top: 18px; display: flex; flex-direction: column; gap: 4px; }
.cnode { padding-top: 8px; }
.comment { display: flex; gap: 12px; }
.comment_main { min-width: 0; flex: 1; }
.comment_body { margin-top: 5px; font-size: 14px; line-height: 1.55; color: var(--color_global); white-space: pre-wrap; word-break: break-word; }
.comment_actions { display: flex; gap: 14px; margin-top: 7px; }
.deleted { font-size: 14px; font-style: italic; color: var(--separator_color_global); padding: 4px 0; }
.children { margin-left: 16px; padding-left: 14px; border-left: var(--border_global); margin-top: 2px; }

/* forms */
.form { display: flex; flex-direction: column; }
.label { font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--separator_color_global); margin: 14px 0 7px; }
.input, .textarea {
  width: 100%; background-color: var(--filling_background-color_global); border: var(--border_global);
  border-radius: 11px; padding: 12px 14px; color: var(--color_global); font-size: 15px; font-family: inherit;
  outline: none; transition: border-color 120ms ease;
}
.input:focus, .textarea:focus { border-color: color-mix(in srgb, var(--hashtag_color_global) 55%, transparent); }
.textarea { resize: vertical; line-height: 1.5; }
.form_actions { display: flex; align-items: center; gap: 10px; margin-top: 14px; }
.error { color: #e24b4a; font-size: 13px; margin-top: 12px; }

/* avatars */
.avatar { border-radius: 50%; object-fit: cover; display: block; flex-shrink: 0; }
.avatar_empty { display: inline-flex; align-items: center; justify-content: center; background-color: var(--item_hover_global); }
.avatar_empty svg { width: 60%; height: 60%; fill: var(--fill_no_avatar_global); }

/* ===== moderators + visibility additions ===== */
.head_actions { display: flex; align-items: center; gap: 10px; }

.lock { width: 14px; height: 14px; margin-right: 6px; vertical-align: -2px; color: var(--separator_color_global); display: inline-block; }
.topic_title .lock { color: var(--hashtag_color_global); }

/* visibility segmented control */
.seg { display: inline-flex; background-color: var(--filling_background-color_global); border: var(--border_global); border-radius: 11px; padding: 3px; gap: 3px; width: fit-content; }
.seg_btn { padding: 8px 18px; border: none; background: none; border-radius: 8px; cursor: pointer; font-size: 14px; font-weight: 700; color: var(--separator_color_global); }
.seg_on { background-color: var(--hashtag_color_global); color: var(--on_accent_global); }

.hint { font-size: 13px; color: var(--separator_color_global); padding: 4px 0; }

/* community multi-select */
.comm_list { display: flex; flex-wrap: wrap; gap: 8px; }
.comm_chip { padding: 8px 14px; border-radius: 10px; border: var(--border_global); background-color: var(--filling_background-color_global); color: var(--color_global); cursor: pointer; font-size: 13px; font-weight: 600; }
.comm_chip_on { background-color: color-mix(in srgb, var(--hashtag_color_global) 16%, transparent); border-color: var(--hashtag_color_global); color: var(--hashtag_color_global); }

/* private badge */
.priv_badge { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: var(--hashtag_color_global); background-color: color-mix(in srgb, var(--hashtag_color_global) 12%, transparent); border-radius: 8px; padding: 5px 10px; margin-bottom: 12px; }
.priv_badge .lock { color: var(--hashtag_color_global); margin: 0; }
.priv_comms { color: var(--separator_color_global); font-weight: 600; text-transform: none; letter-spacing: 0; }

/* moderators panel */
.mod_add { display: flex; gap: 10px; margin: 14px 0; }
.mod_add .input { flex: 1; }
.mods { list-style: none; display: flex; flex-direction: column; gap: 8px; margin-top: 8px; }
.mod_row { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 12px; background-color: var(--filling_background-color_global); border: var(--border_global); }
.mod_id { flex: 1; display: flex; flex-direction: column; }
.mod_handle { font-size: 13px; color: var(--separator_color_global); }
XEOF
echo "  + frontend/src/pages/ForumsPage/ForumsPage.module.css"

cat > /tmp/arcade-logo.b64 << 'B64EOF'
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
B64EOF
node << 'DECODE_EOF'
const fs = require('fs');
fs.writeFileSync('frontend/public/arcade-logo.png', Buffer.from(fs.readFileSync('/tmp/arcade-logo.b64', 'utf8').replace(/\s/g, ''), 'base64'));
console.log('  + frontend/public/arcade-logo.png');
DECODE_EOF
rm -f /tmp/arcade-logo.b64

echo "  wiring schema field, route, branding, locales..."
node << 'NODE_RUN_EOF'
import fs from 'fs';

const F = 'frontend';
const BE = 'backend';

function patch(path, fn) {
  if (!fs.existsSync(path)) { console.log('  (missing, skip)', path); return; }
  const s = fs.readFileSync(path, 'utf8');
  const o = fn(s);
  if (o !== s) { fs.writeFileSync(path, o); console.log('  patched', path); }
  else console.log('  (already done)', path);
}

// 1. user.schema.js — add isModerator (root is additionalProperties:false)
patch(BE + '/src/modules/user/user.schema.js', (s) => {
  if (s.includes('isModerator')) return s;
  return s.replace(
    '    creator: {\n      bsonType: "bool",\n    },',
    '    creator: {\n      bsonType: "bool",\n    },\n    isModerator: {\n      bsonType: "bool",\n    },'
  );
});

// 2. App.jsx — add /forums/moderators route
patch(F + '/src/app/App.jsx', (s) => {
  if (s.includes('forums/moderators')) return s;
  return s.replace(
    '<Route path="/forums/new" element={<ForumsPage />} />',
    '<Route path="/forums/new" element={<ForumsPage />} />\n              <Route path="/forums/moderators" element={<ForumsPage />} />'
  );
});

// 3. LeftSide.jsx — Arcade logo + name
patch(F + '/src/layout/LeftSide/LeftSide.jsx', (s) => {
  s = s.replace('import { CrystalIcon } from "../../shared/ui";\n', '');
  s = s.replace('<CrystalIcon />', '<img src="/arcade-logo.png" alt="Arcade" />');
  s = s.replace('<p>Crystal</p>', '<p>Arcade</p>');
  return s;
});

// 4. LeftSide.module.css — image sizing for the logo
patch(F + '/src/layout/LeftSide/LeftSide.module.css', (s) =>
  s.includes('.crystal_icon img') ? s :
    s + '\n\n/* arcade logo image (replaces crystal svg) */\n.crystal_icon img {\n  display: flex;\n  width: 32px;\n  height: 32px;\n  border-radius: 7px;\n  object-fit: cover;\n}\n.logo_user_not_authorized .crystal_icon img {\n  width: 27px;\n  height: 27px;\n}\n@media (max-width: 1170px) {\n  .crystal_icon img {\n    width: 35px;\n    height: 35px;\n  }\n}\n'
);

// 5. HeaderMobile.jsx — Arcade wordmark
patch(F + '/src/widgets/HeaderMobile/HeaderMobile.jsx', (s) => s.replace('<p>Crystal</p>', '<p>Arcade</p>'));

// 6. locales — moderator + visibility keys
const add = {
  en: { Visibility: "Visibility", Public: "Public", Private: "Private", SelectCommunities: "Visible to communities", NoCommunities: "You're not in any communities yet. Join one to post a private blog.", Moderators: "Moderators", ModeratorsHint: "Add a member as a moderator by their username. Moderators can delete any blog or comment and can see all private blogs.", ModeratorCustomId: "Member username (e.g. johndoe)", AddModerator: "Add", NoModerators: "No moderators yet.", RemoveModerator: "Remove", ConfirmRemoveMod: "Remove this moderator?", NotAllowed: "Only the creator can manage moderators." },
  ru: { Visibility: "Видимость", Public: "Публичный", Private: "Приватный", SelectCommunities: "Видно сообществам", NoCommunities: "Вы пока не состоите в сообществах. Вступите в одно, чтобы опубликовать приватный блог.", Moderators: "Модераторы", ModeratorsHint: "Добавьте участника модератором по его имени пользователя. Модераторы могут удалять любые блоги и комментарии и видят все приватные блоги.", ModeratorCustomId: "Имя пользователя (напр. johndoe)", AddModerator: "Добавить", NoModerators: "Модераторов пока нет.", RemoveModerator: "Убрать", ConfirmRemoveMod: "Убрать этого модератора?", NotAllowed: "Только создатель может управлять модераторами." }
};
for (const lang of ['en', 'ru']) {
  const p = F + '/public/locales/' + lang + '/translation.json';
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  j.ForumsPage = { ...(j.ForumsPage || {}), ...add[lang] };
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
}
console.log('  + locales merged (en, ru)');
NODE_RUN_EOF

echo ""
echo "Done. Moderators + private blogs + Arcade rebrand applied."
