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
