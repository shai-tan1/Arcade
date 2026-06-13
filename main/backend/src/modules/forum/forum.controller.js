// src/modules/forum/forum.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const topics = () => getDB().collection('forumTopics');
const comments = () => getDB().collection('forumComments');

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1
};

const LIMITS = { title: 200, body: 20000, comment: 10000, tag: 30, tags: 6, page: 30 };

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

// score + my vote computed from voter arrays, added to an aggregation pipeline.
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

const authorLookup = {
    $lookup: {
        from: 'users',
        localField: 'authorId',
        foreignField: '_id',
        as: 'author',
        pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
    }
};

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
        const list = await topics().aggregate([
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
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        const now = new Date();
        const doc = {
            authorId: myId,
            title,
            body,
            tags,
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
        const [topic] = await topics().aggregate([
            { $match: { _id: new ObjectId(id) } },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    title: 1,
                    body: 1,
                    tags: 1,
                    author: 1,
                    authorId: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    commentCount: { $ifNull: ['$commentCount', 0] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        topic.isOwner = topic.authorId.equals(myId);
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
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        await topics().updateOne(
            { _id: topic._id },
            { $set: { title, body, tags, updatedAt: new Date() } }
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
        const isCreator = req.userId.creator === true;
        if (!topic.authorId.equals(myId) && !isCreator) return res.status(403).json({ message: 'Not allowed' });

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
        const topic = await topics().findOne({ _id: new ObjectId(id) }, { projection: { _id: 1 } });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        const result = await applyVote(topics(), topic._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- comments ---------------- */

export const listComments = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const list = await comments().aggregate([
            { $match: { topicId: new ObjectId(id) } },
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

        const topic = await topics().findOne({ _id: new ObjectId(id) }, { projection: { _id: 1 } });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });

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

        const author = await getDB().collection('users').findOne({ _id: myId }, { projection: USER_PUBLIC_PROJECTION });
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
        const isCreator = req.userId.creator === true;
        if (!comment.authorId.equals(myId) && !isCreator) return res.status(403).json({ message: 'Not allowed' });
        if (comment.deleted) return res.status(200).json({ status: 'deleted' });

        // Soft delete keeps the thread structure intact for any replies.
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
        const comment = await comments().findOne({ _id: new ObjectId(commentId) }, { projection: { _id: 1, deleted: 1 } });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        if (comment.deleted) return res.status(400).json({ message: 'Comment was deleted' });
        const result = await applyVote(comments(), comment._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};
