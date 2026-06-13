// src/modules/friend/friend.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';
import { emitToUsers } from '../../core/engine/web/websocket.js';

const friendships = () => getDB().collection('friendships');
const users = () => getDB().collection('users');

const COLLATION_OPTIONS = { collation: { locale: 'en', strength: 2 } };

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1,
    'status.lastSeen': 1
};

/* GET /friends -> my accepted friends */
export const getFriends = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const list = await friendships().aggregate([
            { $match: { status: 'accepted', $or: [{ requesterId: myId }, { recipientId: myId }] } },
            {
                $addFields: {
                    otherUser: { $cond: [{ $eq: ['$requesterId', myId] }, '$recipientId', '$requesterId'] }
                }
            },
            {
                $lookup: {
                    from: 'users',
                    localField: 'otherUser',
                    foreignField: '_id',
                    as: 'user',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: '$user' },
            { $project: { _id: 0, friendshipId: '$_id', user: 1 } },
            { $sort: { 'user.name': 1 } }
        ]).toArray();

        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* GET /friends/requests -> { incoming, outgoing } pending */
export const getRequests = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const buildPipeline = (matchField, lookupField) => ([
            { $match: { status: 'pending', [matchField]: myId } },
            {
                $lookup: {
                    from: 'users',
                    localField: lookupField,
                    foreignField: '_id',
                    as: 'user',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: '$user' },
            { $project: { _id: 0, friendshipId: '$_id', user: 1, createdAt: 1 } },
            { $sort: { createdAt: -1 } }
        ]);

        const incoming = await friendships().aggregate(buildPipeline('recipientId', 'requesterId')).toArray();
        const outgoing = await friendships().aggregate(buildPipeline('requesterId', 'recipientId')).toArray();

        res.status(200).json({ incoming, outgoing });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* GET /friends/status/:userId  (:userId = customId) */
export const getStatus = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const other = await users().findOne(
            { customId: req.params.userId },
            { projection: { _id: 1 }, ...COLLATION_OPTIONS }
        );
        if (!other) {
            return res.status(404).json({ message: 'User not found' });
        }
        if (other._id.equals(myId)) {
            return res.status(200).json({ status: 'self', userId: other._id });
        }

        const f = await friendships().findOne({
            $or: [
                { requesterId: myId, recipientId: other._id },
                { requesterId: other._id, recipientId: myId }
            ]
        });

        if (!f) {
            return res.status(200).json({ status: 'none', userId: other._id });
        }
        if (f.status === 'accepted') {
            return res.status(200).json({ status: 'friends', friendshipId: f._id, userId: other._id });
        }
        const direction = f.requesterId.equals(myId) ? 'outgoing' : 'incoming';
        res.status(200).json({ status: direction, friendshipId: f._id, userId: other._id });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /friends/request  body { userId }  (recipient's _id) */
export const sendRequest = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { userId } = req.body;

        if (!userId || !ObjectId.isValid(userId)) {
            return res.status(400).json({ message: 'A valid userId is required' });
        }
        const otherId = new ObjectId(userId);
        if (otherId.equals(myId)) {
            return res.status(400).json({ message: 'You cannot add yourself' });
        }

        const other = await users().findOne({ _id: otherId }, { projection: { _id: 1 } });
        if (!other) {
            return res.status(404).json({ message: 'User not found' });
        }

        const existing = await friendships().findOne({
            $or: [
                { requesterId: myId, recipientId: otherId },
                { requesterId: otherId, recipientId: myId }
            ]
        });
        if (existing) {
            return res.status(409).json({ message: 'A request or friendship already exists' });
        }

        const doc = {
            requesterId: myId,
            recipientId: otherId,
            status: 'pending',
            createdAt: new Date(),
            updatedAt: new Date()
        };
        const result = await friendships().insertOne(doc);

        emitToUsers([userId], { type: 'friend:update' });

        res.status(201).json({ friendshipId: result.insertedId, ...doc });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /friends/:friendshipId/accept  (recipient only) */
export const acceptRequest = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { friendshipId } = req.params;
        if (!ObjectId.isValid(friendshipId)) {
            return res.status(400).json({ message: 'Invalid friendship id' });
        }

        const f = await friendships().findOne({ _id: new ObjectId(friendshipId) });
        if (!f) {
            return res.status(404).json({ message: 'Request not found' });
        }
        if (!f.recipientId.equals(myId)) {
            return res.status(403).json({ message: 'Not allowed' });
        }
        if (f.status !== 'pending') {
            return res.status(400).json({ message: 'Request already handled' });
        }

        await friendships().updateOne(
            { _id: f._id },
            { $set: { status: 'accepted', updatedAt: new Date() } }
        );

        emitToUsers([f.requesterId.toString(), f.recipientId.toString()], { type: 'friend:update' });

        res.status(200).json({ message: 'Accepted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/*
   Remove a friendship/request. Allowed for either party.
   Covers: recipient declines, requester cancels, either unfriends.
   Used by POST /friends/:friendshipId/decline and DELETE /friends/:friendshipId
*/
export const removeFriendship = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { friendshipId } = req.params;
        if (!ObjectId.isValid(friendshipId)) {
            return res.status(400).json({ message: 'Invalid friendship id' });
        }

        const f = await friendships().findOne({ _id: new ObjectId(friendshipId) });
        if (!f) {
            return res.status(404).json({ message: 'Not found' });
        }
        if (!f.recipientId.equals(myId) && !f.requesterId.equals(myId)) {
            return res.status(403).json({ message: 'Not allowed' });
        }

        await friendships().deleteOne({ _id: f._id });

        emitToUsers([f.requesterId.toString(), f.recipientId.toString()], { type: 'friend:update' });

        res.status(200).json({ message: 'Removed' });
    } catch (error) {
        handleServerError(res, error);
    }
};
