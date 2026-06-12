#!/usr/bin/env bash
# Friends + people-search + community join-requests + profile buttons for crystal-v2.0.
# Run from the repo "main/" directory:  bash apply-social-features.sh
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then
  echo "ERROR: run this from ~/crystal-v2.0/main (the folder containing backend/ and frontend/)"; exit 1
fi

mkdir -p "backend/src/modules/friend"
cat > "backend/src/modules/friend/friend.schema.js" << 'CRYSTAL_EOF_7C2F9A6B'
// src/modules/friend/friend.schema.js

export const FRIENDSHIP_SCHEMA = {
    bsonType: 'object',
    required: ['requesterId', 'recipientId', 'status', 'createdAt', 'updatedAt'],
    properties: {
        requesterId: {
            bsonType: 'objectId',
            description: 'user who sent the request; required'
        },
        recipientId: {
            bsonType: 'objectId',
            description: 'user who received the request; required'
        },
        status: {
            enum: ['pending', 'accepted'],
            description: "must be 'pending' or 'accepted'; required"
        },
        createdAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        },
        updatedAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        }
    }
};

export const FRIENDSHIP_INDEXES = [
    // Fast lookup of a relationship between two users (either direction).
    { key: { requesterId: 1, recipientId: 1 } },
    // Fast lookup of requests/friends a user received.
    { key: { recipientId: 1, status: 1 } },
    // Fast lookup of requests/friends a user sent.
    { key: { requesterId: 1, status: 1 } }
];
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/friend/friend.schema.js"

mkdir -p "backend/src/modules/friend"
cat > "backend/src/modules/friend/friend.controller.js" << 'CRYSTAL_EOF_7C2F9A6B'
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
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/friend/friend.controller.js"

mkdir -p "backend/src/modules/friend"
cat > "backend/src/modules/friend/friends.routes.js" << 'CRYSTAL_EOF_7C2F9A6B'
// src/modules/friend/friends.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import {
    getFriends,
    getRequests,
    getStatus,
    sendRequest,
    acceptRequest,
    removeFriendship
} from './friend.controller.js';

const router = express.Router();

// static routes first so they are not captured by /:friendshipId
router.get('/', auth, getFriends);
router.get('/requests', auth, getRequests);
router.get('/status/:userId', auth, getStatus);
router.post('/request', auth, sendRequest);

// id-based actions
router.post('/:friendshipId/accept', auth, acceptRequest);
router.post('/:friendshipId/decline', auth, removeFriendship);
router.delete('/:friendshipId', auth, removeFriendship);

export default router;
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/friend/friends.routes.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/community.schema.js" << 'CRYSTAL_EOF_7C2F9A6B'
// src/modules/community/community.schema.js

export const COMMUNITY_SCHEMA = {
    bsonType: 'object',
    required: ['name', 'creatorId', 'members', 'createdAt'],
    properties: {
        name: {
            bsonType: 'string',
            minLength: 1,
            maxLength: 100,
            description: 'must be a non-empty string and is required'
        },
        description: {
            bsonType: 'string',
            maxLength: 500,
            description: 'optional description'
        },
        avatarUri: {
            bsonType: ['string', 'null'],
            description: 'optional avatar uri'
        },
        isPrivate: {
            bsonType: 'bool',
            description: 'optional; private communities require approval to join'
        },
        creatorId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        members: {
            bsonType: 'array',
            items: { bsonType: 'objectId' },
            description: 'array of member objectIds and is required'
        },
        joinRequests: {
            bsonType: 'array',
            items: { bsonType: 'objectId' },
            description: 'optional; users awaiting approval to join a private community'
        },
        createdAt: {
            bsonType: 'date',
            description: 'must be a date and is required'
        }
    }
};

export const COMMUNITY_INDEXES = [
    { key: { name: 1 } },
    { key: { members: 1 } },
    { key: { createdAt: -1 } }
];

export const COMMUNITY_MESSAGE_SCHEMA = {
    bsonType: 'object',
    required: ['communityId', 'senderId', 'text', 'createdAt'],
    properties: {
        communityId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        senderId: {
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
        }
    }
};

export const COMMUNITY_MESSAGE_INDEXES = [
    { key: { communityId: 1, createdAt: 1 } }
];
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/community/community.schema.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/community.controller.js" << 'CRYSTAL_EOF_7C2F9A6B'
// src/modules/community/community.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';
import { emitToUsers } from '../../core/engine/web/websocket.js';

const communities = () => getDB().collection('communities');
const communityMessages = () => getDB().collection('communityMessages');

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1,
    'status.lastSeen': 1
};

const MAX_TEXT_LENGTH = 5000;
const MAX_NAME_LENGTH = 100;
const MAX_DESCRIPTION_LENGTH = 500;

/* GET /communities — list with member count, membership and request flags */
export const getCommunities = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const list = await communities().aggregate([
            { $sort: { createdAt: -1 } },
            {
                $project: {
                    name: 1,
                    description: 1,
                    avatarUri: 1,
                    creatorId: 1,
                    createdAt: 1,
                    isPrivate: { $ifNull: ['$isPrivate', false] },
                    membersCount: { $size: '$members' },
                    isMember: { $in: [myId, '$members'] },
                    hasRequested: { $in: [myId, { $ifNull: ['$joinRequests', []] }] }
                }
            }
        ]).toArray();

        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /communities — body { name, description?, isPrivate? } */
export const createCommunity = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
        const description = typeof req.body.description === 'string'
            ? req.body.description.trim()
            : '';
        const isPrivate = req.body.isPrivate === true || req.body.isPrivate === 'true';

        if (!name) {
            return res.status(400).json({ message: 'Community name is required' });
        }
        if (name.length > MAX_NAME_LENGTH) {
            return res.status(400).json({ message: `Name is too long (max ${MAX_NAME_LENGTH})` });
        }
        if (description.length > MAX_DESCRIPTION_LENGTH) {
            return res.status(400).json({ message: `Description is too long (max ${MAX_DESCRIPTION_LENGTH})` });
        }

        const doc = {
            name,
            description,
            avatarUri: null,
            isPrivate,
            creatorId: myId,
            members: [myId],
            joinRequests: [],
            createdAt: new Date()
        };

        const result = await communities().insertOne(doc);
        res.status(201).json({ _id: result.insertedId, ...doc });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* GET /communities/:communityId — single community with members + flags */
export const getCommunity = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);

        const found = await communities().aggregate([
            { $match: { _id: new ObjectId(communityId) } },
            {
                $lookup: {
                    from: 'users',
                    localField: 'members',
                    foreignField: '_id',
                    as: 'members',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            {
                $addFields: {
                    isPrivate: { $ifNull: ['$isPrivate', false] },
                    isCreator: { $eq: ['$creatorId', myId] },
                    isMember: { $in: [myId, { $map: { input: '$members', as: 'm', in: '$$m._id' } }] },
                    hasRequested: { $in: [myId, { $ifNull: ['$joinRequests', []] }] }
                }
            },
            { $project: { joinRequests: 0 } }
        ]).toArray();

        if (!found.length) {
            return res.status(404).json({ message: 'Community not found' });
        }

        res.status(200).json(found[0]);
    } catch (error) {
        handleServerError(res, error);
    }
};

/*
   POST /communities/:communityId/join
   Public community  -> join immediately.
   Private community -> register a join request (awaiting approval).
*/
export const joinCommunity = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { members: 1, isPrivate: 1, creatorId: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }

        if (community.members.some((m) => m.equals(myId))) {
            return res.status(200).json({ status: 'member' });
        }

        if (community.isPrivate) {
            await communities().updateOne(
                { _id: communityObjectId },
                { $addToSet: { joinRequests: myId } }
            );
            emitToUsers([community.creatorId.toString()], { type: 'community:request' });
            return res.status(200).json({ status: 'requested' });
        }

        await communities().updateOne(
            { _id: communityObjectId },
            { $addToSet: { members: myId } }
        );
        res.status(200).json({ status: 'member' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /communities/:communityId/leave — also clears any pending request */
export const leaveCommunity = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);

        const result = await communities().updateOne(
            { _id: new ObjectId(communityId) },
            { $pull: { members: myId, joinRequests: myId } }
        );

        if (result.matchedCount === 0) {
            return res.status(404).json({ message: 'Community not found' });
        }

        res.status(200).json({ message: 'Left' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* GET /communities/:communityId/requests — creator only; pending join requests */
export const getJoinRequests = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { creatorId: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }
        if (!community.creatorId.equals(myId)) {
            return res.status(403).json({ message: 'Only the creator can view requests' });
        }

        const result = await communities().aggregate([
            { $match: { _id: communityObjectId } },
            {
                $lookup: {
                    from: 'users',
                    localField: 'joinRequests',
                    foreignField: '_id',
                    as: 'requests',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $project: { _id: 0, requests: 1 } }
        ]).toArray();

        res.status(200).json(result[0]?.requests || []);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /communities/:communityId/requests/:userId/approve — creator only */
export const approveJoinRequest = async (req, res) => {
    try {
        const { communityId, userId } = req.params;
        if (!ObjectId.isValid(communityId) || !ObjectId.isValid(userId)) {
            return res.status(400).json({ message: 'Invalid id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);
        const targetId = new ObjectId(userId);

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { creatorId: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }
        if (!community.creatorId.equals(myId)) {
            return res.status(403).json({ message: 'Only the creator can approve requests' });
        }

        await communities().updateOne(
            { _id: communityObjectId },
            { $pull: { joinRequests: targetId }, $addToSet: { members: targetId } }
        );

        emitToUsers([userId], { type: 'community:request' });

        res.status(200).json({ message: 'Approved' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /communities/:communityId/requests/:userId/decline — creator only */
export const declineJoinRequest = async (req, res) => {
    try {
        const { communityId, userId } = req.params;
        if (!ObjectId.isValid(communityId) || !ObjectId.isValid(userId)) {
            return res.status(400).json({ message: 'Invalid id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);
        const targetId = new ObjectId(userId);

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { creatorId: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }
        if (!community.creatorId.equals(myId)) {
            return res.status(403).json({ message: 'Only the creator can decline requests' });
        }

        await communities().updateOne(
            { _id: communityObjectId },
            { $pull: { joinRequests: targetId } }
        );

        emitToUsers([userId], { type: 'community:request' });

        res.status(200).json({ message: 'Declined' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* GET /communities/:communityId/messages — members only */
export const getCommunityMessages = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { members: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }

        const isMember = community.members.some((m) => m.equals(myId));
        if (!isMember) {
            return res.status(403).json({ message: 'Join the community to view its chat' });
        }

        const chat = await communityMessages().aggregate([
            { $match: { communityId: communityObjectId } },
            { $sort: { createdAt: 1 } },
            {
                $lookup: {
                    from: 'users',
                    localField: 'senderId',
                    foreignField: '_id',
                    as: 'sender',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: { path: '$sender', preserveNullAndEmptyArrays: true } }
        ]).toArray();

        res.status(200).json(chat);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* POST /communities/:communityId/messages — members only; body { text } */
export const sendCommunityMessage = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);
        const communityObjectId = new ObjectId(communityId);

        const trimmed = typeof req.body.text === 'string' ? req.body.text.trim() : '';
        if (!trimmed) {
            return res.status(400).json({ message: 'Message text is required' });
        }
        if (trimmed.length > MAX_TEXT_LENGTH) {
            return res.status(400).json({ message: `Message is too long (max ${MAX_TEXT_LENGTH})` });
        }

        const community = await communities().findOne(
            { _id: communityObjectId },
            { projection: { members: 1 } }
        );
        if (!community) {
            return res.status(404).json({ message: 'Community not found' });
        }

        const isMember = community.members.some((m) => m.equals(myId));
        if (!isMember) {
            return res.status(403).json({ message: 'Join the community to post in its chat' });
        }

        const doc = {
            communityId: communityObjectId,
            senderId: myId,
            text: trimmed,
            createdAt: new Date()
        };

        const result = await communityMessages().insertOne(doc);
        const created = { _id: result.insertedId, ...doc };

        emitToUsers(
            community.members.map((m) => m.toString()),
            { type: 'community:message', communityId }
        );

        res.status(201).json(created);
    } catch (error) {
        handleServerError(res, error);
    }
};
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/community/community.controller.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/communities.routes.js" << 'CRYSTAL_EOF_7C2F9A6B'
// src/modules/community/communities.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import {
    getCommunities,
    createCommunity,
    getCommunity,
    joinCommunity,
    leaveCommunity,
    getJoinRequests,
    approveJoinRequest,
    declineJoinRequest,
    getCommunityMessages,
    sendCommunityMessage
} from './community.controller.js';

const router = express.Router();

// list / create
router.get('/', auth, getCommunities);
router.post('/', auth, createCommunity);

// single community
router.get('/:communityId', auth, getCommunity);

// membership
router.post('/:communityId/join', auth, joinCommunity);
router.post('/:communityId/leave', auth, leaveCommunity);

// join requests (private communities)
router.get('/:communityId/requests', auth, getJoinRequests);
router.post('/:communityId/requests/:userId/approve', auth, approveJoinRequest);
router.post('/:communityId/requests/:userId/decline', auth, declineJoinRequest);

// room chat
router.get('/:communityId/messages', auth, getCommunityMessages);
router.post('/:communityId/messages', auth, sendCommunityMessage);

export default router;
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/community/communities.routes.js"

mkdir -p "backend/src/modules/user"
cat > "backend/src/modules/user/user.controller.js" << 'CRYSTAL_EOF_7C2F9A6B'
// user.controller.js
import { promises as fsPromises } from 'fs';
import path from 'path';
import bcrypt from "bcrypt";
import {
  handleServerError
} from '../../shared/helpers/index.js';

import { getDB } from '../../core/engine/db/connectDB.js';

const users = () => getDB().collection('users');

const COLLATION_OPTIONS = { collation: { locale: "en", strength: 2 } };

const USER_PROJECTION = { email: 0, passwordHash: 0 };


// get user
export const getUser = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne(
      { customId: userId },
      { projection: USER_PROJECTION, ...COLLATION_OPTIONS }
    );

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const userResponse = user;

    // Exclude gender if hideGender === true
    if (userResponse.settings.privacy.hideGender) {
      delete userResponse.profile.gender;
    }

    return res.status(200).json(userResponse);
  } catch (error) {
    handleServerError(res, error);
  }
};
// /get user

// get users
export const getUsers = async (req, res) => {
  try {
    const { exclude, limit, q } = req.query;
    const query = exclude ? { customId: { $ne: exclude } } : {};
    const max = parseInt(limit) || 4;

    // Optional search by name or @customId (case-insensitive).
    if (q && q.trim()) {
      const safe = q.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const rx = new RegExp(safe, 'i');
      query.$or = [{ name: rx }, { customId: rx }];
    }

    const foundUsers = await users().find(query, { projection: USER_PROJECTION })
      .limit(max)
      .sort({ createdAt: -1 })
      .toArray();

    const usersResponse = foundUsers.map(user => {
      // 'user' is already a clean object
      if (user.settings.privacy.hideGender) {
        delete user.profile.gender;
      }
      return user;
    });

    res.status(200).json(usersResponse);
  } catch (error) {
    handleServerError(res, error);
  }
};
// /get users

// get user, for user edit page
export const getUserForUserEditPage = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne(
      { customId: userId },
      { projection: USER_PROJECTION, ...COLLATION_OPTIONS }
    );

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }
    // 'user' is already a clean object
    return res.status(200).json(user);
  } catch (error) {
    handleServerError(res, error);
  }
};

// update user
export const updateUser = async (req, res) => {
  try {
    const userId = req.params.userId;
    const { customId, name, bio, gender, avatarUri, bannerUri } = req.body;

    console.log('req.body = ' + JSON.stringify(req.body))

    // Checking customId
    const newCustomId = customId || 'empty';
    const validation = /^[a-zA-Z0-9-_]{1,35}$/;
    const validationCustomId = validation.test(newCustomId);

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);
    const searchIdenticalUserCustomId = await users().findOne({ customId: newCustomId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: 'User not found' });
    }

    // 'customId' Validation Logic
    const isSameIdCaseInsensitive = userId.toUpperCase() === newCustomId.toUpperCase();
    const isNewIdTaken = searchIdenticalUserCustomId && searchIdenticalUserCustomId._id.toString() !== user._id.toString();

    if (!isSameIdCaseInsensitive && isNewIdTaken) {
      return res.status(409).json({ message: 'This Id already exists' });
    }
    if (!validationCustomId) {
      return res.status(401).json({ message: 'Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed' });
    }

    // 'gender' verification
    if (gender !== undefined) {
      if (!gender || typeof gender !== 'object') {
        return res.status(400).json({ message: "gender must be an object" });
      }
      const { type, customValue } = gender;
      if (!['male', 'female', 'unspecified', 'custom'].includes(type)) {
        return res.status(400).json({ message: "Invalid gender type" });
      }

      /* ⚠️ ATTENTION, DANGER ZONE ❗❗❗
       Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
       After deleting or commenting out this code, gender customization will be enabled, related code in - UserEditPage.jsx ⬇️
       */

      if (type === 'custom') {
        return res.status(403).json({ message: "Gender selection feature is not available" });
      }

      /* /⚠️ ATTENTION, DANGER ZONE ❗❗❗⬆️
       Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
       After deleting or commenting out this code, gender customization will be enabled, related code in - UserEditPage.jsx
       */

      if (type === 'custom' && (!customValue || typeof customValue !== 'string' || customValue.length > 50)) {
        return res.status(400).json({ message: "customValue must be a string up to 50 characters" });
      }

      if (type !== 'custom' && customValue !== undefined) {
        return res.status(400).json({ message: "customValue is only allowed for custom gender type" });
      }
    }

    // Get the old avatarUri and bannerUri values
    const oldAvatarUri = req.body.oldAvatarUri || user.avatarUri || '';
    const oldBannerUri = req.body.oldBannerUri || user.bannerUri || '';

    // We are creating updates
    const updates = {
      name: name !== undefined ? name : user.name,
      customId: newCustomId === 'empty' ? user.customId : newCustomId,
      'profile.bio': bio !== undefined ? bio : user.profile.bio,
      avatarUri: avatarUri !== undefined ? avatarUri : oldAvatarUri,
      bannerUri: bannerUri !== undefined ? bannerUri : oldBannerUri,
      updatedAt: new Date(), // Manually updating the timestamp
    };
    if (gender !== undefined) {
      updates['profile.gender.type'] = gender.type;
      updates['profile.gender.customValue'] = gender.customValue || '';
    }

    // Updating the user

    await users().updateOne(
      { _id: user._id }, // Update by _id for reliability
      { $set: updates }
    );

    // Delete the old avatar if it has changed
    if (avatarUri !== undefined && oldAvatarUri && oldAvatarUri !== avatarUri) {
      const avatarPath = path.join(process.cwd(), oldAvatarUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(avatarPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(avatarPath);
          console.log(`Successfully deleted old avatar: ${avatarPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete old avatar ${avatarPath}:`, err);
      }
    }

    // Delete the old banner if it has changed
    if (bannerUri !== undefined && oldBannerUri && oldBannerUri !== bannerUri) {
      const bannerPath = path.join(process.cwd(), oldBannerUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(bannerPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(bannerPath);
          console.log(`Successfully deleted old banner: ${bannerPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete old banner ${bannerPath}:`, err);
      }
    }

    res.status(200).json({ message: 'User changed' });
  } catch (error) {
    handleServerError(res, error);
  }
};
// /update user

// update user settings
export const updateUserSettings = async (req, res) => {
  try {
    const userId = req.params.userId; // customId ("AndrewShedov")
    const { hideGif, hideGender } = req.body;

    // Input data validation
    if (typeof hideGif !== 'boolean' && typeof hideGender !== 'boolean') {
      return res.status(400).json({ message: "hideGif and hideGender must be boolean values" });
    }

    // Generating updates
    const updates = {
      updatedAt: new Date(),
    };
    if (typeof hideGif === 'boolean') {
      updates['settings.interface.hideGif'] = hideGif;
    }
    if (typeof hideGender === 'boolean') {
      updates['settings.privacy.hideGender'] = hideGender;
    }

    // 1. Atomic update using updateOne (doesn't return the document, but is faster)
    // Using updateOne, which is guaranteed to update and return a count
    const result = await users().updateOne(
      { customId: userId },
      { $set: updates },
      {
        ...COLLATION_OPTIONS
      }
    );

    // Verifying that the user was found and modified
    if (result.matchedCount === 0) {
      return res.status(404).json({ message: "User not found" });
    }

    // 2. SUCCESS: Return a success message, just like in Mongoose
    // Now we know for sure that the database has been updated, and the frontend can update itself
    res.status(200).json({ message: "Settings updated", hideGif, hideGender });

  } catch (error) {
    handleServerError(res, error);
  }
};
// /update user settings

// change user password 
export const changePassword = async (req, res) => {
  try {
    const oldPassword = await req.body.oldPassword;
    const newPassword = await req.body.newPassword;
    const newPasswordValidationRule = /^[a-zA-Z\d!@#$%^&*[\]{}()?"\\/,><':;|_~`=+-]{8,35}$/;
    const validationNewPassword = newPasswordValidationRule.test(newPassword);

    if (!validationNewPassword) {
      return res.status(401).json({ message: "The minimum password length is 8 characters, the maximum is 50, Latin letters, numbers and special characters are allowed." });
    }

    const userId = await req.params.userId;

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const bcryptSalt = await bcrypt.genSalt(10);
    const bcryptHash = await bcrypt.hash(newPassword, bcryptSalt);
    const checkOldPassword = await bcrypt.compare(
      oldPassword,
      user.passwordHash
    );

    if (!checkOldPassword) {
      return res.status(401).send({ message: 'Old password is incorrect' });
    }

    await users().updateOne(
      { _id: user._id },
      {
        $set: {
          passwordHash: bcryptHash,
          updatedAt: new Date(), // Manually updating the timestamp
        }
      }
    );

    res.status(200).json({ message: "Password successfully changed" });
  } catch (error) {
    handleServerError(res, error);
  }
};
// /change user password

// delete user account
export const deleteAccount = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: 'User not found' });
    }

    // deleting an avatar if there is one (логика сохранения)
    if (user.avatarUri) {
      const avatarPath = path.join(process.cwd(), user.avatarUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(avatarPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(avatarPath);
          console.log(`Successfully deleted avatar: ${avatarPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete avatar ${avatarPath}:`, err);
      }
    }

    // removing the banner if there is one (saving logic)
    if (user.bannerUri) {
      const bannerPath = path.join(process.cwd(), user.bannerUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(bannerPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(bannerPath);
          console.log(`Successfully deleted banner: ${bannerPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete banner ${bannerPath}:`, err);
      }
    }

    // deleting a user record
    const result = await users().deleteOne({ _id: user._id });

    if (result.deletedCount === 0) {
      return res.status(404).send('User not found for deletion');
    }

    res.status(200).send('User deleted');
  } catch (error) {
    handleServerError(res, error);
  }
};
// /delete user account
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/modules/user/user.controller.js"

mkdir -p "backend/src/core/engine/db"
cat > "backend/src/core/engine/db/initializeCollections.js" << 'CRYSTAL_EOF_7C2F9A6B'
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
import { FRIENDSHIP_SCHEMA, FRIENDSHIP_INDEXES } from '../../../modules/friend/friend.schema.js';

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

    // 8. Initializing friendships
    await upsertCollection(db, 'friendships', FRIENDSHIP_SCHEMA, FRIENDSHIP_INDEXES);

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
CRYSTAL_EOF_7C2F9A6B
echo "  wrote backend/src/core/engine/db/initializeCollections.js"

mkdir -p "frontend/src/pages/FriendsPage"
cat > "frontend/src/pages/FriendsPage/FriendsPage.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
// frontend/src/pages/FriendsPage/FriendsPage.jsx

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon } from '../../shared/ui';

import styles from './FriendsPage.module.css';

function Avatar({ user }) {
  if (user?.avatarUri) {
    return <img className={styles.avatar} src={API_BASE_URL + user.avatarUri} alt={user.name} />;
  }
  return (
    <span className={`${styles.avatar} ${styles.avatar_empty}`}>
      <NoAvatarIcon />
    </span>
  );
}

function UserRow({ user, children }) {
  return (
    <li className={styles.row}>
      <Link to={`/${user.customId}`} className={styles.row_user}>
        <div className={styles.avatar_wrap}>
          <Avatar user={user} />
          {user.status?.isOnline && <span className={styles.online_dot} />}
        </div>
        <div className={styles.row_text}>
          <span className={styles.row_name}>{user.name}</span>
          <span className={styles.row_id}>@{user.customId}</span>
        </div>
      </Link>
      <div className={styles.row_actions}>{children}</div>
    </li>
  );
}

export function FriendsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();
  const [query, setQuery] = useState('');

  const friendsQuery = useQuery({
    queryKey: ['friends', 'list'],
    queryFn: () => httpClient.get('/friends'),
    retry: false
  });

  const requestsQuery = useQuery({
    queryKey: ['friends', 'requests'],
    queryFn: () => httpClient.get('/friends/requests'),
    retry: false
  });

  const trimmed = query.trim();
  const searchQuery = useQuery({
    queryKey: ['users', 'search', trimmed],
    queryFn: () => {
      const params = { q: trimmed, limit: 20 };
      if (authorizedUser?.customId) params.exclude = authorizedUser.customId;
      return httpClient.get('/users', params);
    },
    enabled: trimmed.length > 0,
    retry: false
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['friends'] });
    queryClient.invalidateQueries({ queryKey: ['users', 'search'] });
  };

  const addMutation = useMutation({
    mutationFn: (userId) => httpClient.post('/friends/request', { userId }),
    onSuccess: invalidate
  });
  const acceptMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/accept`),
    onSuccess: invalidate
  });
  const declineMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/decline`),
    onSuccess: invalidate
  });
  const removeMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.delete(`/friends/${friendshipId}`),
    onSuccess: invalidate
  });

  const friends = friendsQuery.data || [];
  const incoming = requestsQuery.data?.incoming || [];
  const outgoing = requestsQuery.data?.outgoing || [];

  // Relationship lookup so search results show the right button.
  const friendByUserId = new Map(friends.map((f) => [String(f.user._id), f]));
  const outgoingByUserId = new Map(outgoing.map((r) => [String(r.user._id), r]));
  const incomingByUserId = new Map(incoming.map((r) => [String(r.user._id), r]));

  const renderSearchAction = (user) => {
    const id = String(user._id);
    if (friendByUserId.has(id)) {
      return <Link className={styles.btn_secondary} to={`/messages/${user.customId}`}>{t('FriendsPage.Message')}</Link>;
    }
    if (outgoingByUserId.has(id)) {
      return <button className={styles.btn_muted} disabled>{t('FriendsPage.Requested')}</button>;
    }
    if (incomingByUserId.has(id)) {
      return (
        <button className={styles.btn_primary} onClick={() => acceptMutation.mutate(incomingByUserId.get(id).friendshipId)}>
          {t('FriendsPage.Accept')}
        </button>
      );
    }
    return (
      <button className={styles.btn_primary} onClick={() => addMutation.mutate(user._id)} disabled={addMutation.isPending}>
        {t('FriendsPage.AddFriend')}
      </button>
    );
  };

  return (
    <div className={styles.friends_page}>
      <div className={styles.title}>
        <h1>{t('FriendsPage.Friends')}</h1>
      </div>

      {/* Find people */}
      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('FriendsPage.FindPeople')}</h2>
        <input
          className={styles.search_input}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('FriendsPage.SearchPlaceholder')}
        />
        {trimmed.length > 0 && (
          <ul className={styles.list}>
            {searchQuery.isPending && (
              <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
            )}
            {searchQuery.isSuccess && searchQuery.data.length === 0 && (
              <p className={styles.empty}>{t('FriendsPage.NoResults')}</p>
            )}
            {searchQuery.data?.map((user) => (
              <UserRow key={user._id} user={user}>{renderSearchAction(user)}</UserRow>
            ))}
          </ul>
        )}
      </section>

      {/* Incoming requests */}
      {incoming.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.section_title}>{t('FriendsPage.Requests')}</h2>
          <ul className={styles.list}>
            {incoming.map((r) => (
              <UserRow key={r.friendshipId} user={r.user}>
                <button className={styles.btn_primary} onClick={() => acceptMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Accept')}
                </button>
                <button className={styles.btn_muted} onClick={() => declineMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Decline')}
                </button>
              </UserRow>
            ))}
          </ul>
        </section>
      )}

      {/* Outgoing requests */}
      {outgoing.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.section_title}>{t('FriendsPage.Sent')}</h2>
          <ul className={styles.list}>
            {outgoing.map((r) => (
              <UserRow key={r.friendshipId} user={r.user}>
                <button className={styles.btn_muted} onClick={() => removeMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Cancel')}
                </button>
              </UserRow>
            ))}
          </ul>
        </section>
      )}

      {/* My friends */}
      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('FriendsPage.MyFriends')}</h2>
        {friendsQuery.isPending && (
          <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
        )}
        {friendsQuery.isSuccess && friends.length === 0 && (
          <p className={styles.empty}>{t('FriendsPage.NoFriends')}</p>
        )}
        <ul className={styles.list}>
          {friends.map((f) => (
            <UserRow key={f.friendshipId} user={f.user}>
              <Link className={styles.btn_primary} to={`/messages/${f.user.customId}`}>{t('FriendsPage.Message')}</Link>
              <button className={styles.btn_muted} onClick={() => removeMutation.mutate(f.friendshipId)}>
                {t('FriendsPage.Remove')}
              </button>
            </UserRow>
          ))}
        </ul>
      </section>
    </div>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/FriendsPage/FriendsPage.jsx"

mkdir -p "frontend/src/pages/FriendsPage"
cat > "frontend/src/pages/FriendsPage/FriendsPage.module.css" << 'CRYSTAL_EOF_7C2F9A6B'
.friends_page {
  margin-bottom: var(--content_margin_bottom_global);
}

.title {
  padding: 12px 0;
  background-color: var(--filling_background-color_global);
  border-bottom: var(--border_global);
  border-left: var(--border_disappears_in_dark_theme_global);
  border-right: var(--border_disappears_in_dark_theme_global);
}

.title h1 {
  text-align: center;
  font-family: Arial, Helvetica, sans-serif;
  font-size: 22px;
  line-height: 32px;
  color: var(--color_global);
}

.section {
  background-color: var(--filling_background-color_global);
  border-bottom: var(--border_global);
  padding: 14px 16px;
}

.section_title {
  font-size: 15px;
  font-weight: 700;
  color: var(--separator_color_global);
  text-transform: uppercase;
  letter-spacing: 0.03em;
  margin-bottom: 10px;
}

.search_input {
  width: 100%;
  padding: 10px 14px;
  border-radius: 12px;
  border: var(--border_global);
  background-color: var(--background-color_global);
  color: var(--color_global);
  font-family: inherit;
  font-size: 15px;
  outline: none;
}

.list {
  list-style: none;
  margin-top: 8px;
}

.row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 0;
  border-bottom: var(--border_global);
}

.row:last-child {
  border-bottom: none;
}

.row_user {
  display: flex;
  align-items: center;
  gap: 12px;
  flex: 1;
  min-width: 0;
  text-decoration: none;
  color: var(--color_global);
}

.avatar_wrap {
  position: relative;
  flex-shrink: 0;
}

.avatar {
  width: 44px;
  height: 44px;
  border-radius: 50%;
  object-fit: cover;
  display: block;
}

.avatar_empty {
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: var(--item_hover_global);
}

.avatar_empty svg {
  width: 24px;
  height: 24px;
  fill: var(--fill_no_avatar_global);
}

.online_dot {
  position: absolute;
  right: 1px;
  bottom: 1px;
  width: 11px;
  height: 11px;
  border-radius: 50%;
  background-color: #2ecc71;
  border: 2px solid var(--filling_background-color_global);
}

.row_text {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.row_name {
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.row_id {
  font-size: 13px;
  color: var(--separator_color_global);
}

.row_actions {
  display: flex;
  gap: 8px;
  flex-shrink: 0;
}

.btn_primary,
.btn_secondary,
.btn_muted {
  padding: 7px 14px;
  border-radius: 10px;
  border: none;
  cursor: pointer;
  font-size: 14px;
  text-decoration: none;
  white-space: nowrap;
}

.btn_primary {
  background-color: var(--hashtag_color_global);
  color: #fff;
}

.btn_secondary {
  background-color: var(--item_hover_global);
  color: var(--color_global);
}

.btn_muted {
  background-color: transparent;
  border: var(--border_global);
  color: var(--separator_color_global);
}

.btn_primary:disabled,
.btn_muted:disabled {
  opacity: 0.5;
  cursor: default;
}

.empty {
  padding: 16px 0;
  color: var(--separator_color_global);
}

.center_loader {
  height: 80px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.loader {
  height: 21px;
  width: 21px;
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/FriendsPage/FriendsPage.module.css"

mkdir -p "frontend/src/pages/FriendsPage"
cat > "frontend/src/pages/FriendsPage/index.js" << 'CRYSTAL_EOF_7C2F9A6B'
export { FriendsPage } from "./FriendsPage";
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/FriendsPage/index.js"

mkdir -p "frontend/src/pages/CommunitiesPage"
cat > "frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
// frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx

import { useEffect, useRef, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon, EnterIcon, GroupsIcon } from '../../shared/ui';

import styles from './CommunitiesPage.module.css';

function formatTime(value) {
  if (!value) return '';
  return new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function Avatar({ user }) {
  if (user?.avatarUri) {
    return <img className={styles.avatar} src={API_BASE_URL + user.avatarUri} alt={user.name} />;
  }
  return (
    <span className={`${styles.avatar} ${styles.avatar_empty}`}>
      <NoAvatarIcon />
    </span>
  );
}

/* ----------------------------- List + create ----------------------------- */
function CommunityList() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [isPrivate, setIsPrivate] = useState(false);

  const { data, isPending, isError } = useQuery({
    queryKey: ['communities', 'list'],
    queryFn: () => httpClient.get('/communities'),
    retry: false
  });

  const createMutation = useMutation({
    mutationFn: (body) => httpClient.post('/communities', body),
    onSuccess: (created) => {
      setName('');
      setDescription('');
      setIsPrivate(false);
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
      if (created?._id) navigate(`/communities/${created._id}`);
    }
  });

  const joinMutation = useMutation({
    mutationFn: (communityId) => httpClient.post(`/communities/${communityId}/join`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['communities', 'list'] })
  });

  const handleCreate = () => {
    const trimmed = name.trim();
    if (!trimmed || createMutation.isPending) return;
    createMutation.mutate({ name: trimmed, description: description.trim(), isPrivate });
  };

  return (
    <div className={styles.list_wrap}>
      <div className={styles.create_box}>
        <input
          className={styles.create_input}
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder={t('CommunitiesPage.NamePlaceholder')}
          maxLength={100}
        />
        <input
          className={styles.create_input}
          value={description}
          onChange={(event) => setDescription(event.target.value)}
          placeholder={t('CommunitiesPage.DescriptionPlaceholder')}
          maxLength={500}
        />
        <label className={styles.private_toggle}>
          <input
            type="checkbox"
            checked={isPrivate}
            onChange={(event) => setIsPrivate(event.target.checked)}
          />
          <span>{t('CommunitiesPage.PrivateLabel')}</span>
        </label>
        <button
          className={styles.create_button}
          onClick={handleCreate}
          disabled={!name.trim() || createMutation.isPending}
        >
          {t('CommunitiesPage.Create')}
        </button>
      </div>

      {isPending && (
        <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
      )}

      {isError && <p className={styles.empty}>{t('CommunitiesPage.LoadError')}</p>}

      {!isPending && !isError && data?.length === 0 && (
        <p className={styles.empty}>{t('CommunitiesPage.NoCommunities')}</p>
      )}

      <ul className={styles.community_list}>
        {data?.map((community) => (
          <li key={community._id} className={styles.community_item}>
            <span className={`${styles.avatar} ${styles.avatar_empty}`}><GroupsIcon /></span>
            <div className={styles.community_text}>
              <span className={styles.community_name}>{community.name}</span>
              {community.description && (
                <p className={styles.community_description}>{community.description}</p>
              )}
              <span className={styles.community_meta}>
                {community.membersCount} {t('CommunitiesPage.Members')}
              </span>
            </div>
            {community.isMember ? (
              <Link className={styles.open_button} to={`/communities/${community._id}`}>
                {t('CommunitiesPage.Open')}
              </Link>
            ) : community.hasRequested ? (
              <button className={styles.requested_button} disabled>
                {t('CommunitiesPage.Requested')}
              </button>
            ) : (
              <button
                className={styles.join_button}
                onClick={() => joinMutation.mutate(community._id)}
                disabled={joinMutation.isPending}
              >
                {community.isPrivate ? t('CommunitiesPage.RequestToJoin') : t('CommunitiesPage.Join')}
              </button>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

/* ----------------------------- Room chat ----------------------------- */
function CommunityRoom({ communityId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();

  const [text, setText] = useState('');
  const bottomRef = useRef(null);

  const communityQuery = useQuery({
    queryKey: ['communities', communityId],
    queryFn: () => httpClient.get(`/communities/${communityId}`),
    retry: false
  });

  const isMember = communityQuery.data?.isMember;

  const messagesQuery = useQuery({
    queryKey: ['communities', communityId, 'messages'],
    queryFn: () => httpClient.get(`/communities/${communityId}/messages`),
    enabled: !!isMember,
    retry: false
  });

  const joinMutation = useMutation({
    mutationFn: () => httpClient.post(`/communities/${communityId}/join`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['communities', communityId] });
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
    }
  });

  const leaveMutation = useMutation({
    mutationFn: () => httpClient.post(`/communities/${communityId}/leave`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
      navigate('/communities');
    }
  });

  const sendMutation = useMutation({
    mutationFn: (body) => httpClient.post(`/communities/${communityId}/messages`, body),
    onSuccess: () => {
      setText('');
      queryClient.invalidateQueries({ queryKey: ['communities', communityId, 'messages'] });
    }
  });

  const isCreator = communityQuery.data?.isCreator;

  const requestsQuery = useQuery({
    queryKey: ['communities', communityId, 'requests'],
    queryFn: () => httpClient.get(`/communities/${communityId}/requests`),
    enabled: !!isCreator,
    retry: false
  });

  const approveMutation = useMutation({
    mutationFn: (userId) => httpClient.post(`/communities/${communityId}/requests/${userId}/approve`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['communities', communityId] });
      queryClient.invalidateQueries({ queryKey: ['communities', communityId, 'requests'] });
    }
  });

  const declineMutation = useMutation({
    mutationFn: (userId) => httpClient.post(`/communities/${communityId}/requests/${userId}/decline`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['communities', communityId, 'requests'] })
  });

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messagesQuery.data?.length]);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed || sendMutation.isPending) return;
    sendMutation.mutate({ text: trimmed });
  };

  const handleKeyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSend();
    }
  };

  if (communityQuery.isPending) {
    return <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>;
  }

  if (communityQuery.isError) {
    return (
      <div className={styles.room}>
        <div className={styles.room_header}>
          <button className={styles.back_button} onClick={() => navigate('/communities')}>←</button>
        </div>
        <p className={styles.empty}>{t('CommunitiesPage.LoadError')}</p>
      </div>
    );
  }

  const community = communityQuery.data;
  const myId = authorizedUser?._id;

  return (
    <div className={styles.room}>
      <div className={styles.room_header}>
        <button className={styles.back_button} onClick={() => navigate('/communities')} aria-label="Back">←</button>
        <span className={`${styles.avatar} ${styles.avatar_empty}`}><GroupsIcon /></span>
        <div className={styles.room_header_text}>
          <span className={styles.community_name}>{community.name}</span>
          <span className={styles.community_meta}>
            {community.members?.length || 0} {t('CommunitiesPage.Members')}
          </span>
        </div>
        {isMember && (
          <button
            className={styles.leave_button}
            onClick={() => leaveMutation.mutate()}
            disabled={leaveMutation.isPending}
          >
            {t('CommunitiesPage.Leave')}
          </button>
        )}
      </div>

      {!isMember ? (
        <div className={styles.join_prompt}>
          {community.hasRequested ? (
            <>
              <p>{t('CommunitiesPage.RequestPending')}</p>
              <button className={styles.requested_button} disabled>
                {t('CommunitiesPage.Requested')}
              </button>
            </>
          ) : (
            <>
              <p>{community.isPrivate ? t('CommunitiesPage.RequestToChat') : t('CommunitiesPage.JoinToChat')}</p>
              <button
                className={styles.join_button}
                onClick={() => joinMutation.mutate()}
                disabled={joinMutation.isPending}
              >
                {community.isPrivate ? t('CommunitiesPage.RequestToJoin') : t('CommunitiesPage.Join')}
              </button>
            </>
          )}
        </div>
      ) : (
        <>
          {isCreator && requestsQuery.data?.length > 0 && (
            <div className={styles.requests_panel}>
              <span className={styles.requests_title}>
                {t('CommunitiesPage.JoinRequests')} ({requestsQuery.data.length})
              </span>
              {requestsQuery.data.map((user) => (
                <div key={user._id} className={styles.request_row}>
                  <Link to={`/${user.customId}`} className={styles.request_user}>
                    <span className={`${styles.avatar} ${styles.avatar_empty} ${styles.avatar_sm}`}>
                      {user.avatarUri
                        ? <img className={styles.avatar_img} src={API_BASE_URL + user.avatarUri} alt={user.name} />
                        : <NoAvatarIcon />}
                    </span>
                    <span className={styles.request_name}>{user.name} <span className={styles.request_id}>@{user.customId}</span></span>
                  </Link>
                  <div className={styles.request_actions}>
                    <button className={styles.join_button} onClick={() => approveMutation.mutate(user._id)}>
                      {t('CommunitiesPage.Approve')}
                    </button>
                    <button className={styles.leave_button} onClick={() => declineMutation.mutate(user._id)}>
                      {t('CommunitiesPage.Decline')}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
          <div className={styles.messages_scroll}>
            {messagesQuery.isPending && (
              <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
            )}
            {messagesQuery.data?.length === 0 && (
              <p className={styles.empty}>{t('CommunitiesPage.NoMessages')}</p>
            )}
            {messagesQuery.data?.map((message) => {
              const isOwn = String(message.senderId) === String(myId);
              return (
                <div
                  key={message._id}
                  className={isOwn ? `${styles.bubble} ${styles.bubble_own}` : styles.bubble}
                >
                  {!isOwn && (
                    <Link to={`/${message.sender?.customId}`} className={styles.bubble_author}>
                      {message.sender?.name || t('CommunitiesPage.Unknown')}
                    </Link>
                  )}
                  <span className={styles.bubble_text}>{message.text}</span>
                  <span className={styles.bubble_time}>{formatTime(message.createdAt)}</span>
                </div>
              );
            })}
            <div ref={bottomRef} />
          </div>

          <div className={styles.composer}>
            <textarea
              className={styles.composer_input}
              value={text}
              onChange={(event) => setText(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder={t('CommunitiesPage.TypeMessage')}
              rows={1}
            />
            <button
              className={styles.send_button}
              onClick={handleSend}
              disabled={!text.trim() || sendMutation.isPending}
              aria-label="Send"
            >
              <EnterIcon />
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/* ----------------------------- Page ----------------------------- */
export function CommunitiesPage() {
  const { communityId } = useParams();
  const { t } = useTranslation();

  return (
    <div className={styles.communities_page}>
      <div className={styles.title}>
        <h1>{t('CommunitiesPage.Communities')}</h1>
      </div>
      {communityId ? <CommunityRoom communityId={communityId} /> : <CommunityList />}
    </div>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx"

mkdir -p "frontend/src/pages/CommunitiesPage"
cat > "frontend/src/pages/CommunitiesPage/CommunitiesPage.module.css" << 'CRYSTAL_EOF_7C2F9A6B'
.communities_page {
  margin-bottom: var(--content_margin_bottom_global);
}

.title {
  padding: 12px 0;
  background-color: var(--filling_background-color_global);
  border-bottom: var(--border_global);
  border-left: var(--border_disappears_in_dark_theme_global);
  border-right: var(--border_disappears_in_dark_theme_global);
}

.title h1 {
  text-align: center;
  font-family: Arial, Helvetica, sans-serif;
  font-size: 22px;
  line-height: 32px;
  color: var(--color_global);
}

/* ---------- shared ---------- */
.avatar {
  width: 44px;
  height: 44px;
  border-radius: 50%;
  object-fit: cover;
  display: block;
  flex-shrink: 0;
}

.avatar_empty {
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: var(--item_hover_global);
}

.avatar_empty svg {
  width: 24px;
  height: 24px;
  fill: none;
  stroke: var(--fill_no_avatar_global);
}

.empty {
  text-align: center;
  padding: 40px 20px;
  color: var(--separator_color_global);
}

.center_loader {
  height: 200px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.loader {
  height: 21px;
  width: 21px;
}

/* ---------- create + list ---------- */
.list_wrap {
  background-color: var(--filling_background-color_global);
}

.create_box {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  border-bottom: var(--border_global);
}

.create_input {
  padding: 10px 12px;
  border-radius: 10px;
  border: var(--border_global);
  background-color: var(--background-color_global);
  color: var(--color_global);
  font-family: inherit;
  font-size: 15px;
  outline: none;
}

.create_button {
  align-self: flex-start;
  padding: 9px 18px;
  border: none;
  border-radius: 10px;
  cursor: pointer;
  background-color: var(--hashtag_color_global);
  color: #fff;
  font-size: 15px;
}

.create_button:disabled {
  opacity: 0.5;
  cursor: default;
}

.community_list {
  list-style: none;
}

.community_item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
  border-bottom: var(--border_global);
}

.community_text {
  flex: 1;
  min-width: 0;
}

.community_name {
  font-weight: 600;
  color: var(--color_global);
  text-decoration: none;
}

.community_description {
  margin-top: 2px;
  font-size: 14px;
  color: var(--separator_color_global);
}

.community_meta {
  display: block;
  margin-top: 2px;
  font-size: 12px;
  color: var(--separator_color_global);
}

.open_button,
.join_button,
.leave_button {
  flex-shrink: 0;
  padding: 7px 16px;
  border-radius: 10px;
  border: none;
  cursor: pointer;
  font-size: 14px;
  text-decoration: none;
}

.open_button {
  background-color: var(--item_hover_global);
  color: var(--color_global);
}

.join_button {
  background-color: var(--hashtag_color_global);
  color: #fff;
}

.leave_button {
  background-color: transparent;
  border: var(--border_global);
  color: var(--separator_color_global);
}

.join_button:disabled,
.leave_button:disabled {
  opacity: 0.5;
  cursor: default;
}

/* ---------- room ---------- */
.room {
  display: flex;
  flex-direction: column;
  height: 70vh;
  background-color: var(--filling_background-color_global);
}

.room_header {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 16px;
  border-bottom: var(--border_global);
}

.room_header_text {
  flex: 1;
  min-width: 0;
}

.back_button {
  background: none;
  border: none;
  cursor: pointer;
  font-size: 22px;
  line-height: 1;
  color: var(--color_global);
  padding: 0 4px;
}

.join_prompt {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 16px;
  color: var(--separator_color_global);
}

.messages_scroll {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.bubble {
  max-width: 72%;
  align-self: flex-start;
  background-color: var(--item_hover_global);
  color: var(--color_global);
  padding: 8px 12px;
  border-radius: 14px;
  border-bottom-left-radius: 4px;
  display: flex;
  flex-direction: column;
  word-break: break-word;
}

.bubble_own {
  align-self: flex-end;
  background-color: var(--hashtag_color_global);
  color: #fff;
  border-bottom-left-radius: 14px;
  border-bottom-right-radius: 4px;
}

.bubble_author {
  font-size: 12px;
  font-weight: 600;
  margin-bottom: 2px;
  color: var(--hashtag_color_global);
  text-decoration: none;
}

.bubble_text {
  white-space: pre-wrap;
}

.bubble_time {
  margin-top: 3px;
  font-size: 11px;
  opacity: 0.7;
  align-self: flex-end;
}

.composer {
  display: flex;
  align-items: flex-end;
  gap: 8px;
  padding: 10px 12px;
  border-top: var(--border_global);
}

.composer_input {
  flex: 1;
  resize: none;
  max-height: 120px;
  padding: 10px 12px;
  border-radius: 18px;
  border: var(--border_global);
  background-color: var(--background-color_global);
  color: var(--color_global);
  font-family: inherit;
  font-size: 15px;
  line-height: 20px;
  outline: none;
}

.send_button {
  flex-shrink: 0;
  width: 40px;
  height: 40px;
  border-radius: 50%;
  border: none;
  cursor: pointer;
  background-color: var(--hashtag_color_global);
  display: flex;
  align-items: center;
  justify-content: center;
}

.send_button:disabled {
  opacity: 0.5;
  cursor: default;
}

.send_button svg {
  width: 18px;
  height: 18px;
  fill: #fff;
  stroke: #fff;
}

/* ---------- private toggle + join requests (added for request flow) ---------- */
.private_toggle {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 14px;
  color: var(--separator_color_global);
  cursor: pointer;
  user-select: none;
}

.private_toggle input {
  width: 16px;
  height: 16px;
  cursor: pointer;
}

.requested_button {
  flex-shrink: 0;
  padding: 7px 16px;
  border-radius: 10px;
  border: var(--border_global);
  background-color: transparent;
  color: var(--separator_color_global);
  font-size: 14px;
  cursor: default;
}

.requests_panel {
  border-bottom: var(--border_global);
  padding: 12px 16px;
  background-color: var(--background-color_global);
}

.requests_title {
  display: block;
  font-size: 13px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--separator_color_global);
  margin-bottom: 8px;
}

.request_row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 0;
}

.request_user {
  display: flex;
  align-items: center;
  gap: 10px;
  flex: 1;
  min-width: 0;
  text-decoration: none;
  color: var(--color_global);
}

.avatar_sm {
  width: 34px;
  height: 34px;
}

.avatar_img {
  width: 100%;
  height: 100%;
  border-radius: 50%;
  object-fit: cover;
}

.request_name {
  font-size: 14px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.request_id {
  font-weight: 400;
  color: var(--separator_color_global);
}

.request_actions {
  display: flex;
  gap: 6px;
  flex-shrink: 0;
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/CommunitiesPage/CommunitiesPage.module.css"

mkdir -p "frontend/src/pages"
cat > "frontend/src/pages/index.js" << 'CRYSTAL_EOF_7C2F9A6B'
export { HomePage } from "./HomePage";
export { SearchPage } from "./SearchPage";
export { FullPostPage } from "./FullPostPage";
export { PostCreatePage } from "./PostCreatePage";
export { PostEditPage } from "./PostEditPage";
export { UserProfilePage } from "./UserProfilePage";
export { UserEditPage } from "./UserEditPage";
export { HashtagPage } from "./HashtagPage";
export { LikesPage } from "./LikesPage";
export { MessagesPage } from "./MessagesPage";
export { CommunitiesPage } from "./CommunitiesPage";
export { FriendsPage } from "./FriendsPage";
export { NotFoundPage } from "./NotFoundPage";
export { TermsPage } from "./TermsPage";
export { PrivacyPage } from "./PrivacyPage";
export { CookiesPolicyPage } from "./CookiesPolicyPage";
export { AboutCrystalPage } from "./AboutCrystalPage";
export { AgreementsPage } from "./AgreementsPage";
export { HelpPage } from "./HelpPage";
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/index.js"

mkdir -p "frontend/src/app"
cat > "frontend/src/app/App.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
// frontend/src/app/App.jsx
import {
  Routes,
  Route,
  useLocation
} from 'react-router-dom';
import { useSelector } from 'react-redux';
import { useEffect } from 'react';

import { useAuth } from "../features";
import {
  AccessModal,
  MoreAboutUserModal,
  SideMenuMobile,
  SideMenuMobileBackground,
} from '../features';
import { useWebSocket } from '../shared/hooks';
import {
  HomePage,
  SearchPage,
  FullPostPage,
  PostCreatePage,
  PostEditPage,
  UserProfilePage,
  UserEditPage,
  HashtagPage,
  LikesPage,
  MessagesPage,
  CommunitiesPage,
  FriendsPage,
  NotFoundPage,
  TermsPage,
  PrivacyPage,
  CookiesPolicyPage,
  AboutCrystalPage,
  AgreementsPage,
  HelpPage
} from '../pages';
import {
  SearchAndSort,
  CookiesBanner,
  UpButton
} from '../shared/ui';
import { HeaderMobile } from '../widgets';
import {
  RightSide,
  LeftSide
} from '../layout';

import styles from './App.module.css';

export default function App() {

  useAuth()

  useWebSocket();

  const location = useLocation()
  const defineFullPostPage = location.pathname.includes('/posts/')

  // dark theme
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  useEffect(() => {
    const html = document.documentElement;
    html.setAttribute('data-dark-theme', String(darkThemeStatus));
  }, [darkThemeStatus]);
  // /dark theme

  return (
    <div className={styles.app}>
      <div className={styles.left_center_right_parts_wrap}>
        <div className={styles.left_center_right_parts}>
          <div className={styles.left_side_wrap}>
            <LeftSide />
          </div>
          <div className={
            defineFullPostPage
              ? `${styles.center} ${styles.center_full}`
              : styles.center
          }>
            <div className={styles.header_mobile_wrap}>
              <HeaderMobile />
              <SideMenuMobile />
            </div>

            <SearchAndSort />

            <Routes>
              <Route path="/" element={<HomePage />} />

              {/* search */}
              <Route path="/search" element={<SearchPage />} />
              {/* /search */}

              {/* users */}
              <Route path="/:userId" element={<UserProfilePage />} />
              <Route path="/users/:userId/edit" element={<UserEditPage />} />
              <Route path="/likes/:userId" element={<LikesPage />} />
              {/* /users */}

              {/* messages */}
              <Route path="/messages" element={<MessagesPage />} />
              <Route path="/messages/:userId" element={<MessagesPage />} />
              {/* /messages */}

              {/* communities */}
              <Route path="/communities" element={<CommunitiesPage />} />
              <Route path="/communities/:communityId" element={<CommunitiesPage />} />
              {/* /communities */}

              {/* friends */}
              <Route path="/friends" element={<FriendsPage />} />
              {/* /friends */}

              {/* posts */}
              <Route path="/posts/:postId" element={<FullPostPage />} />
              <Route path="/posts/new" element={<PostCreatePage />} />
              <Route path="/posts/:postId/edit" element={<PostEditPage />} />
              <Route path="/hashtags/:tag" element={<HashtagPage />} />
              {/* /posts */}

              {/* agreements */}
              <Route path="/agreements" element={<AgreementsPage />} />
              <Route path="/terms" element={<TermsPage />} />
              <Route path="/privacy" element={<PrivacyPage />} />
              <Route path="/cookies-policy" element={<CookiesPolicyPage />} />
              {/* /agreements */}

              {/* others */}
              <Route path="/about-crystal" element={<AboutCrystalPage />} />
              <Route path="/help" element={<HelpPage />} />
              {/* /others */}

              {/* 404 */}
              <Route path="*" element={<NotFoundPage />} />
              {/* /404 */}

            </Routes>

          </div>
          <div className={styles.right_side_wrap}>
            <RightSide />
          </div>
        </div>
      </div>
      <CookiesBanner />
      <AccessModal />
      <MoreAboutUserModal />
      <SideMenuMobileBackground />
      <UpButton />
    </div>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/app/App.jsx"

mkdir -p "frontend/src/widgets/SideMenuDesktop"
cat > "frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
import { useSelector } from 'react-redux';
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";

import { useAuthData } from "../../features";
import {
  UserIcon,
  SettingsIcon,
  MessagesIcon,
  FriendsIcon,
  GroupsIcon,
  PhotosIcon,
  VideosIcon,
  BookmarkIcon,
  HelpIcon,
  CrystalIcon,
  LikeIcon,
  DocumentationIcon,
} from '../../shared/ui';

import styles from "./SideMenuDesktop.module.css";

export function SideMenuDesktop() {

  const { authorizedUser } = useAuthData();
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);
  const { t } = useTranslation();

  if (!authorizedUser) {
    return null
  }

  return (
    <nav
      className={styles.side_menu_desktop}
      data-side-menu-desktop-dark-theme={darkThemeStatus}
    >
      <ul>
        <li className={styles.user}>
          <UserIcon />
          <p>{t("SideMenuDesktop.MyProfile")}</p>
          <Link to={"/" + authorizedUser.customId}></Link>
        </li>
        
        {/* --- FIXED: Messages Link --- */}
        <li className={styles.messages}>
          <MessagesIcon />
          <p>{t("SideMenuDesktop.Messages")}</p>
          <Link to="/messages"></Link> 
        </li>
        {/* --------------------------- */}

        <li className={styles.friends}>
          <FriendsIcon />
          <p>{t("SideMenuDesktop.Friends")}</p>
          <Link to="/friends"></Link>
        </li>
        <li className={styles.groups}>
          <GroupsIcon />
          <p>{t("SideMenuDesktop.Communities")}</p>
          <Link to="/communities"></Link>
        </li>
        <li className={styles.photo}>
          <PhotosIcon />
          <p>{t("SideMenuDesktop.Photo")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.video}>
          <VideosIcon />
          <p>{t("SideMenuDesktop.Video")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.bookmark}>
          <BookmarkIcon />
          <p>{t("SideMenuDesktop.Bookmarks")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.like}>
          <LikeIcon />
          <p>{t("SideMenuDesktop.Likes")}</p>
          <Link to={"/likes/" + authorizedUser.customId}></Link>
        </li>
        <li className={styles.settings}>
          <SettingsIcon />
          <p>{t("SideMenuDesktop.Settings")}</p>
          <Link to={`/users/${authorizedUser.customId}/edit`}></Link>
        </li>
        <li className={styles.crystal}>
          <CrystalIcon />
          <p>{t("SideMenuDesktop.AboutCrystal")}</p>
          <Link to={"/about-crystal"} target="_blank"></Link>
        </li>
        <li className={styles.agreements}>
          <DocumentationIcon />
          <p>{t("SideMenuDesktop.Agreements")}</p>
          <Link to={"/agreements"} target="_blank"></Link>
        </li>
        <li className={styles.help}>
          <HelpIcon />
          <p>{t("SideMenuDesktop.Help")}</p>
          <Link to={"/help"} target="_blank"></Link>
        </li>
      </ul>
    </nav>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx"

mkdir -p "frontend/src/shared/hooks/useWebSocket"
cat > "frontend/src/shared/hooks/useWebSocket/useWebSocket.js" << 'CRYSTAL_EOF_7C2F9A6B'
// frontend/src/shared/hooks/useWebSocket.js

import { useEffect, useRef, useState, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useAuthData } from '../../../features';
import { WS_URL } from '../../../shared/constants';

const generateTabId = () => {
  return (Date.now() + Math.random())
    .toString(36)
    .replace('.', '')
    .substring(2);
};

export function useWebSocket() {
  const queryClient = useQueryClient();
  const { authorizedUser, isSuccess: isAuthSuccess } = useAuthData();
  
  const wsRef = useRef(null);
  const tabIdRef = useRef(generateTabId());
  
  // Trigger for hard reset of connection
  const [reconnectCount, setReconnectCount] = useState(0);
  
  const hiddenTimeoutRef = useRef(null);
  
  // A flag to let you know if we've gone into "long sleep"
  const wasHiddenRef = useRef(false);

  const [wsState, setWsState] = useState({
    isConnected: false,
    isPending: false,
    isError: false,
    isSuccess: false,
  });

  const closeSocket = useCallback((socket, code, reason) => {
    if (socket) {
      socket.onclose = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onopen = null;
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close(code, reason);
      }
    }
  }, []);

  useEffect(() => {
    if (!isAuthSuccess || !authorizedUser?._id) {
      if (wsRef.current) {
        if (wsRef.current.readyState === WebSocket.OPEN) {
          wsRef.current.send(JSON.stringify({
            type: 'logout',
            userId: authorizedUser?._id || 'unknown',
            tabId: tabIdRef.current,
          }));
        }
        closeSocket(wsRef.current, 1000, 'User logged out');
        wsRef.current = null;
      }
      return;
    }

    // We generate a new ID for each new connection.
    tabIdRef.current = generateTabId();
    const currentTabId = tabIdRef.current;
    const userId = authorizedUser._id;

    setWsState(prev => ({ ...prev, isPending: true, isError: false }));

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState({ isConnected: true, isPending: false, isError: false, isSuccess: true });
      wasHiddenRef.current = false; // Reset the "was hidden" flag
      
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'visibility',
          status: 'visible', // Always visible on startup
          userId,
          tabId: currentTabId,
        }));
        ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
      }

      ws.activityInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
          ws.send('ping');
        }
      }, 30000); 
    };

    ws.onmessage = (event) => {
      try {
        if (event.data === 'pong') return;
        const data = JSON.parse(event.data);
        
        //  Change of status 'online', in real time (Optimistic update on socket event) 
        if (data.type === 'user:online' || data.type === 'user:offline') {
          const isOnlineNow = data.type === 'user:online';
          
          // 1. Instantly refresh the cache for THIS specific user
          // It doesn't matter whether we look at this user's profile or the list where he is.
          queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
             if (!oldData || !oldData.data) return oldData;
             
             // If the ID in the cache matches the ID from the socket event
             if (oldData.data._id === data.userId) {
               return {
                 ...oldData,
                 data: {
                   ...oldData.data,
                   status: {
                     ...oldData.data.status,
                     isOnline: isOnlineNow, // Set status instantly
                     // If you're logged in, update lastSeen to "now"
                     lastSeen: isOnlineNow ? new Date().toISOString() : oldData.data.status.lastSeen
                   }
                 }
               };
             }
             return oldData;
          });

          // 2. And only then do we start the background update (for reliability)
          queryClient.invalidateQueries({ queryKey: ['users'] });
        }

        // New direct message -> refresh conversations and the open thread
        if (data.type === 'message:new') {
          queryClient.invalidateQueries({ queryKey: ['messages'] });
        }

        // New community message -> refresh the affected room
        if (data.type === 'community:message') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }

        // Friend request / accept / change -> refresh friends + requests
        if (data.type === 'friend:update') {
          queryClient.invalidateQueries({ queryKey: ['friends'] });
        }

        // Community join request created / approved / declined
        if (data.type === 'community:request') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }
      } catch (error) {
        console.error('[WS] Parse error:', error);
      }
    };

    ws.onclose = (event) => {
      setWsState(prev => ({ ...prev, isConnected: false, isSuccess: false }));
      if (ws.activityInterval) clearInterval(ws.activityInterval);

      // Auto-reconnect if the connection is lost
      if (ws === wsRef.current && isAuthSuccess) {
        setTimeout(() => {
             setReconnectCount(prev => prev + 1); 
        }, 1000);
      }
    };

    ws.onerror = (error) => {
      console.error('[WS] Error:', error);
      setWsState(prev => ({ ...prev, isError: true }));
      ws.close(); 
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        // 🟢 WE'RE BACK!

        // We immediately update the data from the server
        queryClient.invalidateQueries({ queryKey: ['users'] });

        // Optimistic Renewal of Ourselves (So that the light bulb immediately turns on in us)
        queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
           if (!oldData || !oldData.data) return oldData;
           if (oldData.data._id === userId) {
             return { ...oldData, data: { ...oldData.data, status: { ...oldData.data.status, isOnline: true } } };
           }
           return oldData;
        });

        if (hiddenTimeoutRef.current) {
          clearTimeout(hiddenTimeoutRef.current);
          hiddenTimeoutRef.current = null;
          wasHiddenRef.current = false;
          return; 
        }

        // Hard Reconnect After a Long Sleep
        if (wasHiddenRef.current || !ws || ws.readyState !== WebSocket.OPEN) {
           setReconnectCount(c => c + 1);
        } else {
           ws.send(JSON.stringify({ type: 'visibility', status: 'visible', userId, tabId: currentTabId }));
           ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
        }

      } else {
         // 🔴 WE'RE LEAVING
         if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
         
         hiddenTimeoutRef.current = setTimeout(() => {
             wasHiddenRef.current = true; // Let's remember that we have "officially" gone into invisibility.
             if (ws.readyState === WebSocket.OPEN) {
                 ws.send(JSON.stringify({ type: 'visibility', status: 'hidden', userId, tabId: currentTabId }));
             }
             hiddenTimeoutRef.current = null;
         }, 4000); // exit (hidden) in 4 seconds
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);

    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      if (ws.activityInterval) clearInterval(ws.activityInterval);
      if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
      closeSocket(ws, 1000, 'Cleanup/Reconnecting');
    };

  }, [isAuthSuccess, authorizedUser?._id, queryClient, reconnectCount, closeSocket]);

  return {
    isConnected: wsState.isConnected,
    isPending: wsState.isPending,
    isError: wsState.isError,
    isSuccess: wsState.isSuccess,
  };
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/shared/hooks/useWebSocket/useWebSocket.js"

mkdir -p "frontend/src/pages/UserProfilePage/parts/UserInformation"
cat > "frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
// frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.jsx

import { Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../../../shared/api';
import styles from './ProfileActions.module.css';

export function ProfileActions({ profileCustomId, profileUserId }) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const statusQuery = useQuery({
    queryKey: ['friends', 'status', profileCustomId],
    queryFn: () => httpClient.get(`/friends/status/${profileCustomId}`),
    enabled: !!profileCustomId,
    retry: false
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['friends'] });
  };

  const addMutation = useMutation({
    mutationFn: () => httpClient.post('/friends/request', { userId: profileUserId }),
    onSuccess: invalidate
  });
  const acceptMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/accept`),
    onSuccess: invalidate
  });
  const removeMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.delete(`/friends/${friendshipId}`),
    onSuccess: invalidate
  });

  const status = statusQuery.data?.status;
  const friendshipId = statusQuery.data?.friendshipId;

  // Hide entirely while loading, on error, or on your own profile.
  if (statusQuery.isPending || statusQuery.isError || status === 'self') {
    return null;
  }

  return (
    <div className={styles.actions}>
      <Link className={styles.message} to={`/messages/${profileCustomId}`}>
        {t('ProfileActions.Message')}
      </Link>

      {status === 'none' && (
        <button
          className={styles.primary}
          onClick={() => addMutation.mutate()}
          disabled={addMutation.isPending}
        >
          {t('ProfileActions.AddFriend')}
        </button>
      )}

      {status === 'outgoing' && (
        <button className={styles.muted} disabled>
          {t('ProfileActions.Requested')}
        </button>
      )}

      {status === 'incoming' && (
        <button
          className={styles.primary}
          onClick={() => acceptMutation.mutate(friendshipId)}
        >
          {t('ProfileActions.Accept')}
        </button>
      )}

      {status === 'friends' && (
        <button
          className={styles.muted}
          onClick={() => removeMutation.mutate(friendshipId)}
        >
          {t('ProfileActions.Friends')}
        </button>
      )}
    </div>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.jsx"

mkdir -p "frontend/src/pages/UserProfilePage/parts/UserInformation"
cat > "frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.module.css" << 'CRYSTAL_EOF_7C2F9A6B'
.actions {
  display: flex;
  gap: 10px;
  padding: 4px 0 2px;
  flex-wrap: wrap;
}

.message,
.primary,
.muted {
  padding: 8px 18px;
  border-radius: 10px;
  border: none;
  cursor: pointer;
  font-size: 14px;
  font-family: Arial, Helvetica, sans-serif;
  text-decoration: none;
  white-space: nowrap;
}

.message {
  background-color: var(--item_hover_global);
  color: var(--color_global);
}

.primary {
  background-color: var(--hashtag_color_global);
  color: #fff;
}

.muted {
  background-color: transparent;
  border: var(--border_global);
  color: var(--separator_color_global);
}

.primary:disabled,
.muted:disabled {
  opacity: 0.6;
  cursor: default;
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.module.css"

mkdir -p "frontend/src/pages/UserProfilePage/parts/UserInformation"
cat > "frontend/src/pages/UserProfilePage/parts/UserInformation/UserInformation.jsx" << 'CRYSTAL_EOF_7C2F9A6B'
import {
  useState,
  useEffect,
  useRef
} from 'react';
import {
  useDispatch,
  useSelector
} from 'react-redux';
import {
  useParams,
  Link
} from 'react-router-dom';
import {
  useQuery,
  useMutation,
  useQueryClient
} from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../../../shared/api';
import { API_BASE_URL } from '../../../../shared/constants';
import { useAuthData } from '../../../../features';
import {
  setShowMoreAboutUserModal,
  setUserId
} from '../../../../features/moreAboutUserModal/moreAboutUserModalSlice';
import {
  useFormattedLastSeenDate,
  useFormattedLastSeenDateShort
} from '../../../../shared/hooks';
import { setShowAccessModal } from "../../../../features/accessModal/accessModalSlice";
import {
  LoadingBar,
  NoAvatarIcon,
  DeleteIcon,
  CameraIcon,
  AcceptIcon,
  CrystalIcon,
  ThreeDotsIcon,
  GifInCircleIcon,
  WordGifIcon,
  Loader,
  UserOnlineStatusCircleIcon
} from '../../../../shared/ui';
import { NotFoundPage } from '../../../../pages';
import { convertImage } from '../../../../shared/utils';
import { formatLinksInText } from '../../../../shared/helpers';

import { ProfileActions } from './ProfileActions';

import styles from './UserInformation.module.css';

export function UserInformation() {

  const {
    authorizedUser,
    isPending: isAuthPending,
    isSuccess: isAuthSuccess
  } = useAuthData();

  const logInStatus = useSelector(
    (state) => state.logInStatus
  );

  const darkThemeStatus = useSelector(
    (state) => state.darkThemeStatus
  );

  const dispatch = useDispatch();
  const queryClient = useQueryClient();
  const { t } = useTranslation();

  // user options, menu
  const menuUserOptions = useRef();

  const [
    showMenuUserOptions,
    setShowMenuUserOptions
  ] = useState(false);

  const [
    menuUserOptionsFadeOut,
    setMenuUserOptionsFadeOut
  ] = useState(false);

  const buttonShowMenuPostOptions = (Visibility) => {
    if (Visibility) {
      setShowMenuUserOptions(true);
    } else {
      setMenuUserOptionsFadeOut(true);
    }
  };

  // closing a menu when clicking outside its field
  useEffect(() => {
    if (menuUserOptions.current) {
      const handler = (event) => {
        event.stopPropagation();
        if (!menuUserOptions.current.contains(event.target)) {
          setMenuUserOptionsFadeOut(true);
        }
      };
      document.addEventListener('mousedown', handler);
      return () => document.removeEventListener('mousedown', handler);
    }
  },);
  // /closing a menu when clicking outside its field

  const { userId } = useParams();
  const authorizedUserAccessCheck = authorizedUser?.creator || authorizedUser?.customId === userId;

  // checking whether the user has posts
  const [userHavePosts, setUserHavePost] = useState(false);
  const userPosts = useQuery({
    queryKey: ['posts', 'userInformationUserHavePosts', userId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () => httpClient.get(`/posts/user/${userId}`).then((response) => response),
  });

  useEffect(() => {
    setUserHavePost(userPosts.data?.totalPosts > 0 ? true : false);
  }, [userPosts]);

  const user = useQuery({
    queryKey: ['users', 'userProfilePageUserData', userId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () => httpClient.get(`/users/${userId}`).then((response) => response),
  });

  // banner useState
  const [
    databaseHaveBanner,
    setDatabaseHaveBanner
  ] = useState(true);

  const [
    databaseBannerUri,
    setDatabaseBannerUri
  ] = useState();

  const [fileBannerUrl, setFileBannerUrl] = useState();
  const [fileBanner, setFileBanner] = useState();
  // /banner useState

  const inputAddFileBannerRef = useRef();

  // avatar useState
  const [
    databaseHaveAvatar,
    setDatabaseHaveAvatar
  ] = useState(true);

  const [
    databaseAvatarUri,
    setDatabaseAvatarUri
  ] = useState();

  const [fileAvatarUrl, setFileAvatarUrl] = useState();
  const [fileAvatar, setFileAvatar] = useState();
  // /avatar useState

  const inputAddFileAvatarRef = useRef();

  const [userName, setUserName] = useState();
  const [userCustomId, setUserCustomId] = useState();
  const [userBio, setUserBio] = useState();

  const [
    creatorCrystalStatus,
    setCreatorCrystalStatus
  ] = useState();

  const [
    showBannerButtons,
    setShowBannerButtons
  ] = useState(false);

  const [
    showAvatarButtons,
    setShowAvatarButtons
  ] = useState(false);

  const saveBannerMutation = useMutation({
    mutationKey: ['saveBanner'],
    mutationFn: async () => {
      const file = fileBanner;
      const oldBannerUri = user?.data?.bannerUri || '';

      if (!databaseHaveBanner && !fileBanner) {
        await httpClient.patch(`/users/${userId}`, { bannerUri: '', oldBannerUri });
      } else if (file instanceof File) {
        const formData = new FormData();
        formData.append('image', file);
        const { imageUri } = await httpClient.post(`/users/${userId}/image`, formData);
        await httpClient.patch(`/users/${userId}`, { bannerUri: imageUri, oldBannerUri });
      }
    },
    onSuccess: () => {
      setFileBannerUrl(undefined);
      setFileBanner(undefined);
      if (inputAddFileBannerRef.current?.value) {
        inputAddFileBannerRef.current.value = '';
      }
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
    },
    onError: (error) => {
      console.warn('❌ Error uploading banner:', error);
      if (error?.error === 'File size exceeds 2.5 MB limit.') {
        alert(t('Common.LargeImageError'));
      } else {
        alert(t('Common.UploadingImageError'));
      }
    },
  });

  const onClickSaveBanner = () => {
    saveBannerMutation.mutate();
  };

  const onClickDeleteUserBanner = () => {
    setDatabaseHaveBanner(false);
    setDatabaseBannerUri(undefined);
    setFileBannerUrl(undefined);
    setFileBanner(null);
    inputAddFileBannerRef.current.value = '';
  };

  const saveAvatarMutation = useMutation({
    mutationKey: ['saveAvatar'],
    mutationFn: async () => {
      const file = fileAvatar;
      const oldAvatarUri = user?.data?.avatarUri || '';

      if (!databaseHaveAvatar && !fileAvatar) {
        await httpClient.patch(`/users/${userId}`, { avatarUri: '', oldAvatarUri });
      } else if (file instanceof File) {
        const formData = new FormData();
        formData.append('image', file);
        const { imageUri } = await httpClient.post(`/users/${userId}/image`, formData);
        await httpClient.patch(`/users/${userId}`, { avatarUri: imageUri, oldAvatarUri });
      }
    },

    onSuccess: () => {
      setFileAvatarUrl(undefined);
      setFileAvatar(undefined);
      if (inputAddFileAvatarRef.current?.value) {
        inputAddFileAvatarRef.current.value = '';
      }
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
    },
    onError: (error) => {
      console.warn('❌ Error uploading avatar:', error);
      if (error?.error === 'File size exceeds 2.5 MB limit.') {
        alert(t('Common.LargeImageError'));
      } else {
        alert(t('Common.UploadingImageError'));
      }
    },
  });

  const onClickSaveAvatar = () => {
    saveAvatarMutation.mutate();
  };

  const onClickDeleteUserAvatar = () => {
    setDatabaseHaveAvatar(false);
    setDatabaseAvatarUri(undefined);
    setFileAvatarUrl(undefined);
    setFileAvatar(null);
    inputAddFileAvatarRef.current.value = '';
  };

  useEffect(() => {
    if (user.isSuccess) {
      setDatabaseAvatarUri(user.data?.avatarUri ? API_BASE_URL + user.data.avatarUri : undefined);
      setDatabaseHaveAvatar(!!user.data?.avatarUri);
      setDatabaseBannerUri(user.data?.bannerUri ? API_BASE_URL + user.data.bannerUri : undefined);
      setDatabaseHaveBanner(!!user.data?.bannerUri);
      setUserName(user.data?.name);
      setUserCustomId(user.data?.customId);
      setUserBio(user.data?.profile?.bio);
      setCreatorCrystalStatus(user.data?.creator);
    }
  }, [user.data, user.status]);

  // convert avatar image
  const [
    avatarImageLoadingStatus,
    setAvatarImageLoadingStatus
  ] = useState(false);

  const [
    avatarImageLoadingStatusError,
    setAvatarImageLoadingStatusError
  ] = useState(false);

  useEffect(() => {
    if (avatarImageLoadingStatus === 100) {
      setTimeout(() => setAvatarImageLoadingStatus(false), 500);
    }
    if (avatarImageLoadingStatusError) {
      setTimeout(() => setAvatarImageLoadingStatusError(false), 3500);
    }
  }, [avatarImageLoadingStatus, avatarImageLoadingStatusError]);

  async function onChangeConvertAvatarImage(event) {
    setAvatarImageLoadingStatusError(false);
    setAvatarImageLoadingStatus(0);
    const imageFile = event.target.files[0];

    try {
      let webpFile;
      if (imageFile.type === 'image/gif') {
        for (let i = 0; i <= 100; i += 5) {
          await new Promise((res) => setTimeout(res, 10));
          setAvatarImageLoadingStatus(i);
        }
        webpFile = imageFile;
      } else {
        webpFile = await convertImage(imageFile, {
          newFileName: 'preview.webp',
          targetSizeBytes: 307200,
          fallbackQuality: 0.1,
          maxWidthOrHeight: 1920,
          onProgress: (progress) => setAvatarImageLoadingStatus(progress),
        });
      }
      setFileAvatar(webpFile);
      setFileAvatarUrl(URL.createObjectURL(webpFile));
      setTimeout(() => setAvatarImageLoadingStatus(false), 300);
      setAvatarImageLoadingStatusError(false);
    } catch (error) {
      console.log(error);
      setAvatarImageLoadingStatusError(true);
      setAvatarImageLoadingStatus(false);
    }
  }
  // /convert avatar image

  // convert banner image
  const [
    bannerImageLoadingStatus,
    setBannerImageLoadingStatus
  ] = useState(false);

  const [
    bannerImageLoadingStatusError,
    setBannerImageLoadingStatusError
  ] = useState(false);

  useEffect(() => {
    if (bannerImageLoadingStatus === 100) {
      setTimeout(() => setBannerImageLoadingStatus(false), 500);
    }
    if (bannerImageLoadingStatusError) {
      setTimeout(() => setBannerImageLoadingStatusError(false), 3500);
    }
  }, [
    bannerImageLoadingStatus,
    bannerImageLoadingStatusError
  ]);

  async function onChangeCompressedBannerImage(event) {
    setBannerImageLoadingStatusError(false);
    setBannerImageLoadingStatus(0);
    const imageFile = event.target.files[0];

    try {
      let webpFile;
      if (imageFile.type === 'image/gif') {
        for (let i = 0; i <= 100; i += 5) {
          await new Promise((res) => setTimeout(res, 10));
          setBannerImageLoadingStatus(i);
        }
        webpFile = imageFile;
      } else {
        webpFile = await convertImage(imageFile, {
          newFileName: 'preview.webp',
          targetSizeBytes: 307200,
          fallbackQuality: 0.1,
          maxWidthOrHeight: 1920,
          onProgress: (progress) => setBannerImageLoadingStatus(progress),
        });
      }
      setFileBanner(webpFile);
      setFileBannerUrl(URL.createObjectURL(webpFile));
      setTimeout(() => setBannerImageLoadingStatus(false), 300);
      setBannerImageLoadingStatusError(false);
    } catch (error) {
      console.log(error);
      setBannerImageLoadingStatusError(true);
      setBannerImageLoadingStatus(false);
    }
  }
  // /convert banner image

  // Restore the image and buttons to their original state when switching to another user's page

  useEffect(() => {

    // 1. Resetting the states of downloaded files
    setFileBanner(undefined);
    setFileBannerUrl(undefined);
    setFileAvatar(undefined);
    setFileAvatarUrl(undefined);

    // 2. Resetting progress bar states (if loading was in progress during the transition)
    setAvatarImageLoadingStatus(false);
    setAvatarImageLoadingStatusError(false);
    setBannerImageLoadingStatus(false);
    setBannerImageLoadingStatusError(false);

    // 3. Resetting the values in the inputs (so that you can select the same file again)
    if (inputAddFileBannerRef.current) {
      inputAddFileBannerRef.current.value = '';
    }
    if (inputAddFileAvatarRef.current) {
      inputAddFileAvatarRef.current.value = '';
    }

    // 4. Close the menus
    setShowBannerButtons(false);
    setShowAvatarButtons(false);

  }, [userId]);

  // /Restore the image and buttons to their original state when switching to another user's page

  const openMoreAboutUserModal = () => {
    dispatch(setUserId(userId));
    dispatch(setShowMoreAboutUserModal(true));
  };

  // const { isConnected, isPending, isError, isSuccess } = useWebSocket();

  const userOnline = user?.data?.status?.isOnline;

  const genderType = user?.data?.profile?.gender?.type || 'unspecified';

  // formatted last seen

  const [
    showFormattedLastSeen,
    setShowFormattedLastSeen
  ] = useState(false);

  const formattedLastSeen = useFormattedLastSeenDate(user?.data?.status?.lastSeen, genderType);

  const formattedLastSeenShort = useFormattedLastSeenDateShort(user.data?.status.lastSeen);

  // spawn timer for lastSeenShort
  const [
    isVisibleLastSeenShort,
    setIsVisibleLastSeenShort
  ] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => {
      setIsVisibleLastSeenShort(true);
    }, 500);

    return () => clearTimeout(timer);
  }, []);
  // /spawn timer for lastSeenShort

  // /formatted last seen

  // Logic to hide "Last seen" for very short durations
  // Determine the lines that need to be hidden (0-2 seconds, in Russian and English)
  const shortLastSeenExclusions = ['0 с', '1 с', '2 с', '0 s', '1 s', '2 s'];

  // Checking whether it is necessary to hide the short “was online”
  const shouldHideLastSeenShort = shortLastSeenExclusions.includes(formattedLastSeenShort);

  // Combined logic to display the short "was online"
  const shouldShowLastSeenShort = isVisibleLastSeenShort && user.data?.status.lastSeen && !shouldHideLastSeenShort;

  return (
    <>
      {(user.isPending || (logInStatus && isAuthPending)) && (
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}
      {user.isError && <NotFoundPage />}
      {user.isSuccess && (!logInStatus || isAuthSuccess) && (
        <div
          className={userHavePosts ? styles.user_information : styles.user_information_no_posts}
          data-user-information-dark-theme={darkThemeStatus}
        >
          <div
            className={styles.banner}
            onMouseOver={() => setShowBannerButtons(true)}
            onMouseOut={() => setShowBannerButtons(false)}
          >
            {(databaseHaveBanner || fileBannerUrl) && (
              fileBannerUrl ? (
                <img src={fileBannerUrl} alt="banner" />
              ) : databaseBannerUri?.endsWith('.gif') && logInStatus && (authorizedUser?.settings.interface.hideGif ?? false) ? (
                <div className={styles.word_gif_icon}>
                  <WordGifIcon />
                </div>
              ) : databaseBannerUri ? (
                <img src={databaseBannerUri} alt="banner" />
              ) : null
            )}
            {(authorizedUserAccessCheck && !saveBannerMutation.isPending) && (
              <div
                className={
                  showBannerButtons
                    ? `${styles.banner_buttons_wrap} ${styles.banner_buttons_wrap_show}`
                    : styles.banner_buttons_wrap
                }
              >
                <button className={styles.add_banner_button} onClick={() => inputAddFileBannerRef.current.click()}>
                  <CameraIcon />
                </button>
                {(fileBanner instanceof File || (fileBanner === null && !databaseHaveBanner)) && (
                  <button className={styles.save_banner_button} onClick={onClickSaveBanner}>
                    <AcceptIcon />
                  </button>
                )}
                <input
                  ref={inputAddFileBannerRef}
                  type="file"
                  accept="image/*"
                  onChange={(event) => onChangeCompressedBannerImage(event)}
                  hidden
                />
                {(databaseHaveBanner || fileBanner) && (
                  <button className={styles.delete_banner_button} onClick={onClickDeleteUserBanner}>
                    <DeleteIcon />
                  </button>
                )}
              </div>
            )}
            {saveBannerMutation.isPending && (
              <div className={styles.banner_save_loader}>
                <Loader />
              </div>
            )}
          </div>
          <div className={styles.user_options}>
            <button
              onClick={() =>
                logInStatus
                  ? buttonShowMenuPostOptions(!showMenuUserOptions)
                  : dispatch(setShowAccessModal(true))
              }
            >
              <ThreeDotsIcon />
            </button>
            {showMenuUserOptions && (
              <nav
                ref={menuUserOptions}
                className={
                  menuUserOptionsFadeOut
                    ? `${styles.user_options_menu} ${styles.user_options_menu_fade_out}`
                    : styles.user_options_menu
                }
                onAnimationEnd={(e) => {
                  if (e.animationName === styles.fadeOut) {
                    setShowMenuUserOptions(false);
                    setMenuUserOptionsFadeOut(false);
                  }
                }}
              >
                <ul>
                  {authorizedUserAccessCheck && (
                    <li>
                      <Link to={`/users/${userId}/edit`}>{t('UserInformation.EditUser')}</Link>
                    </li>
                  )}
                </ul>
              </nav>
            )}
          </div>
          {bannerImageLoadingStatus ? (
            <div className={styles.banner_image_loading_bar_wrap}>
              <LoadingBar value={bannerImageLoadingStatus} />
            </div>
          ) : null}
          {bannerImageLoadingStatusError && (
            <div className={styles.banner_image_loading_error}>
              <p>{t('SystemMessages.Error')}</p>
            </div>
          )}
          <div
            className={
              !userName && !userBio
                ? `${styles.avatar_name_wrap} ${styles.avatar_name_wrap_without_name_without_about}`
                : styles.avatar_name_wrap
            }
          >
            <div
              className={!userBio ? `${styles.avatar_name} ${styles.avatar_name_without_about}` : styles.avatar_name}
            >
              <div className={styles.avatar_wrap}>
                <div
                  className={userName ? styles.avatar : `${styles.avatar} ${styles.avatar_without_name}`}
                  onMouseOver={(event) => {
                    event.stopPropagation();
                    setShowAvatarButtons(true);
                  }}
                  onMouseOut={(event) => {
                    event.stopPropagation();
                    setShowAvatarButtons(false);
                  }}
                >
                  {(databaseHaveAvatar || fileAvatarUrl) ? (
                    fileAvatarUrl ? (
                      <img src={fileAvatarUrl} alt="avatar" />
                    ) : databaseAvatarUri?.endsWith('.gif') && logInStatus && (authorizedUser?.settings.interface.hideGif ?? false) ? (
                      <div className={styles.gif_circle_icon}>
                        <GifInCircleIcon />
                      </div>
                    ) : databaseAvatarUri ? (
                      <img src={databaseAvatarUri} alt="avatar" />
                    ) : null
                  ) : (
                    <div className={styles.no_avatar_icon}>
                      <NoAvatarIcon />
                    </div>
                  )}
                  {(authorizedUserAccessCheck && !saveAvatarMutation.isPending) && (
                    <div
                      className={
                        showAvatarButtons
                          ? `${styles.avatar_buttons_wrap} ${styles.avatar_buttons_wrap_show}`
                          : styles.avatar_buttons_wrap
                      }
                    >
                      <div
                        className={styles.avatar_buttons}
                      >
                        <button
                          className={styles.add_avatar_button}
                          onClick={() => inputAddFileAvatarRef.current.click()}
                        >
                          <CameraIcon />
                        </button>
                        {(fileAvatar instanceof File || (fileAvatar === null && !databaseHaveAvatar)) && (
                          <button className={styles.save_avatar_button} onClick={onClickSaveAvatar}>
                            <AcceptIcon />
                          </button>
                        )}
                        <input
                          ref={inputAddFileAvatarRef}
                          type="file"
                          accept="image/*"
                          onChange={(event) => onChangeConvertAvatarImage(event)}
                          hidden
                        />
                        {(databaseHaveAvatar || fileAvatar) && (
                          <button className={styles.delete_avatar_button} onClick={onClickDeleteUserAvatar}>
                            <DeleteIcon />
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                  {avatarImageLoadingStatus ? (
                    <div className={styles.avatar_image_loading_bar_wrap}>
                      <LoadingBar value={avatarImageLoadingStatus} />
                    </div>
                  ) : null}
                  {avatarImageLoadingStatusError && (
                    <div className={styles.avatar_image_loading_error}>
                      <p>{t('SystemMessages.Error')}</p>
                    </div>
                  )}

                  {(userOnline) ? (
                    <div className={styles.user_online_status_circle_icon}>
                      <UserOnlineStatusCircleIcon />
                    </div>
                  ) : (

                    //initially - isVisibleLastSeenShort &&
                    (shouldShowLastSeenShort) && (
                      <div className={styles.last_seen_short_icon}
                        onMouseOver={(event) => {
                          event.stopPropagation();
                          setShowFormattedLastSeen(true);
                        }}
                        onMouseOut={(event) => {
                          event.stopPropagation();
                          setShowFormattedLastSeen(false);
                        }}
                      >
                        <p>{formattedLastSeenShort}</p>
                      </div>
                    )
                  )}

                  {showFormattedLastSeen && (
                    <div className={styles.last_seen_wrap}>
                      <p>{formattedLastSeen}</p>
                    </div>
                  )}
                </div>
                {saveAvatarMutation.isPending && (
                  <div className={styles.avatar_save_loader}>
                    <Loader />
                  </div>
                )}
              </div>
              <div className={styles.name_id_wrap}>
                {userName && (
                  <div className={styles.name}>
                    <p>{userName}</p>
                    {creatorCrystalStatus && (
                      <div className={styles.crystal_icon}>
                        <CrystalIcon />
                      </div>
                    )}
                  </div>
                )}
                {userCustomId && (
                  <div className={styles.id}>
                    <p>@{userCustomId}</p>
                  </div>
                )}
              </div>
            </div>
          </div>
          {logInStatus && authorizedUser?.customId !== userId && user.data?._id && (
            <ProfileActions profileCustomId={userId} profileUserId={user.data._id} />
          )}
          {userBio && (
            <div className={styles.about_wrap}>
              <div className={userName ? styles.about : styles.about_without_name}>
                <p>{formatLinksInText(userBio)}</p>
              </div>
            </div>
          )}
          {/* additional information */}
          <div className={
            userName ?
              styles.additional_information_wrap
              :
              `${styles.additional_information_wrap} ${styles.additional_information_wrap_no_name}`
          }>
            <div className={styles.additional_information_wrap_button}>
              <button onClick={openMoreAboutUserModal}>
                {t("UserInformation.ShowMore")}
              </button>
            </div>
          </div>
          {/* /additional information */}
        </div >
      )
      }
    </>
  );
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/src/pages/UserProfilePage/parts/UserInformation/UserInformation.jsx"

mkdir -p "frontend/public/locales/en"
cat > "frontend/public/locales/en/translation.json" << 'CRYSTAL_EOF_7C2F9A6B'
{
  "SystemMessages": {
    "Error": "Error"
  },
  "Common": {
    "LargeImageError": "❌ Maximum GIF size - 2.5MB",
    "UploadingImageError": "❌ Error uploading image."
  },
  "AccessModal": {
    "SwitchLogIn": "Log In",
    "SwitchSignUp": "Sign Up",
    "InputNameLogIn": "Name",
    "InputNameSignUp": "Name",
    "InputErrorNameEmpty": "Enter a name",
    "InputErrorNameMinimumLength": "The minimum length of the name is 1 character",
    "InputErrorNameMaximumLength": "The maximum length of the name is 200 characters",
    "InputErrorIdAlreadyExists": "This Id already exists",
    "InputErrorIdMinimumLength": "Minimum length of Id - 1 character",
    "InputErrorIdMaximumLength": "Maximum length of Id - 35 characters",
    "InputErrorIdMinimumMaximumLengthSymbols": "Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed",
    "InputEmail": "Email",
    "InputErrorEmailMaximumLength": "The maximum length of an email is 100 characters",
    "InputErrorEmailAlreadyExists": "This email already exists",
    "InputPasswordLogIn": "Password",
    "InputPasswordSignUp": "* Password",
    "InputErrorEmailEmpty": "Enter email",
    "InputErrorPasswordEmpty": "Enter password",
    "InputErrorPasswordMinimumMaximumLengthSymbols": "The minimum password length is 8 characters, the maximum is 50, Latin letters, numbers and special characters are allowed",
    "InputErrorEmailPasswordWrong": "Invalid email or password",
    "InputErrorAcceptTerms": "It is necessary to accept the conditions",
    "Terms": "I accept the <1>terms of user agreement</1>, <2>privacy policy</2> and <3>cookies policy</3>."
  },
  "User": {
    "UserDeleted": "User deleted"
  },
  "PostCreatePage": {
    "CreatePost": "Create a post",
    "Text": "Text",
    "Title": "Title",
    "AddMainImage": "Add image",
    "ChangeMainImage": "Change",
    "DeleteMainImage": "Delete",
    "Publish": "Publish",
    "Back": "Back",
    "FailedCreatePost": "Failed to create post"
  },
  "PostEditPage": {
    "EditPost": "Edit post",
    "AddMainImage": "Add image",
    "Change": "Change",
    "Delete": "Delete",
    "Publish": "Publish",
    "Text": "Text",
    "Title": "Title",
    "Back": "Back",
    "FailedSaveChanges": "Failed to save changes"
  },
  "UserEditPage": {
    "EditUser": "Editing user and settings",
    "Settings": "Settings",
    "Interface": "Interface",
    "Privacy": "Privacy",
    "HideGif": "Hide GIF",
    "ShowGif": "Show GIF",
    "UserName": "Name",
    "UserBio": "About me",
    "DeleteAllYourPostsButton": "Delete all posts",
    "DeleteAllUserPostsButton": "Delete all posts",
    "DeleteAllYourPosts": "Delete all posts ? Posts will be deleted without the possibility of recovery.",
    "DeleteAllPostsByUser": "Delete all user posts ? Posts will be deleted permanently.",
    "AllPostsDeleted": "All posts deleted",
    "DeleteAccount": "Delete account",
    "DeleteAccountQuestion": "Delete user account ? The account will be deleted without the possibility of recovery.",
    "DeleteUserAccount": "Delete user account",
    "SaveChanges": "Save changes",
    "Save": "Save",
    "IdErrorMinimumMaximumLengthSymbols": "Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed",
    "IdAlreadyExists": "This Id already exists",
    "ChangePassword": "Change password",
    "Hide": "Hide",
    "OldPassword": "Old password",
    "NewPassword": "New password",
    "OldPasswordIncorrect": "Old password is incorrect",
    "PasswordRequirements": "The password may contain Latin letters, numbers and special characters.",
    "PasswordSuccessfullyChanged": "Password successfully changed",
    "Gender": "Gender",
    "Female": "female",
    "Male": "male",
    "Unspecified": "unspecified",
    "CustomGender": "Self-identify",
    "GenderError": "Floor update error.",
    "GenderSelectionNotAvailable": "Gender selection feature is not available",
    "HideGender": "Hide Gender",
    "ShowGender": "Show Gender"
  },
  "CookiesBanner": {
    "Text": "This website uses cookies. By clicking the 'Accept' button or continuing to use the website, you agree to the use of cookies.",
    "ButtonMoreDetails": "More details",
    "ButtonAccept": "Accept"
  },
  "SideMenuDesktop": {
    "MyProfile": "My profile",
    "Messages": "Messages",
    "Friends": "Friends",
    "Communities": "Communities",
    "Photo": "Photo",
    "Video": "Video",
    "Likes": "Likes",
    "Settings": "Settings",
    "Bookmarks": "Bookmarks",
    "AboutCrystal": "About Crystal",
    "Agreements": "Agreements",
    "Help": "Help"
  },
  "SideMenuMobile": {
    "MyProfile": "My profile",
    "Messages": "Messages",
    "Friends": "Friends",
    "Communities": "Communities",
    "Photo": "Photo",
    "Video": "Video",
    "Likes": "Likes",
    "Bookmarks": "Bookmarks",
    "AboutCrystal": "About Crystal",
    "Agreements": "Agreements",
    "Help": "Help"
  },
  "CurrentTopics": {
    "CurrentTopics": "Current topics",
    "ShowMore": "Show more",
    "Post": "Post",
    "PostsAverage": "Posts",
    "Posts": "posts",
    "key_one": "post",
    "key_other": "posts"
  },
  "RecommendedUsers": {
    "YouMightLike": "You might like",
    "Subscribe": "Subscribe",
    "ShowMore": "Show more"
  },
  "OptionsMenuGuest": {
    "AboutCrystal": "About CRYSTAL",
    "Agreements": "Agreements",
    "Help": "Help"
  },
  "PostSourceMenu": {
    "Subscriptions": "Subscriptions",
    "Preferences": "Preferences",
    "Mine": "Mine",
    "World": "World"
  },
  "OptionsMenuUser": {
    "MyProfile": "My profile",
    "Settings": "Settings",
    "Agreements": "Agreements",
    "Help": "Help",
    "Exit": "Exit",
    "LogOut": "Log out of your account ?"
  },
  "PostPreview": {
    "DeleteAccountQuestion": "Delete user account ?",
    "DeleteAllUserPostsQuestion": "Delete all posts by user?",
    "DeletePostQuestion": "Delete post ?",
    "UserDeleted": "User deleted",
    "EditPost": "Edit",
    "DeletePost": "Delete",
    "DeleteAllUserPosts": "Delete all user posts",
    "DeleteUser": "Delete user",
    "add": "add",
    "upd": "upd"
  },
  "FullPostPage": {
    "DeleteAccountQuestion": "Delete user account ?",
    "DeleteAllUserPostsQuestion": "Delete all posts by user?",
    "DeletePostQuestion": "Delete post ?",
    "UserDeleted": "User deleted",
    "EditPost": "Edit",
    "DeletePost": "Delete",
    "DeleteAllUserPosts": "Delete all user posts",
    "DeleteUser": "Delete user",
    "add": "add",
    "upd": "upd"
  },
  "UserInformation": {
    "EditUser": "Edit",
    "FailedDeleteAvatar": "❌ Failed to delete avatar",
    "FailedDeleteBanner": "❌ Failed to delete banner",
    "ShowMore": "Show more",
    "Hide": "Hide"
  },
  "LikesPage": {
    "LikedPosts": "Likes",
    "NolikedPosts": "No liked posts"
  },
  "MoreAboutUserModal": {
    "DetailedInformation": "Detailed information",
    "Gender": "Gender",
    "Female": "female",
    "Male": "male",
    "Unspecified": "unspecified",
    "Registration": "Registration date",
    "Update": "Update"
  },
  "UseFormattedLastSeenDateShort": {
    "seconds": "s",
    "minutes": "min",
    "hours": "h",
    "days": "d",
    "months": "mon",
    "key_one": "y",
    "key_other": "y"
  },
  "UseFormattedLastSeenDate": {
    "prefix": "Last seen",
    "ago": "ago",
    "yesterday": "yesterday",
    "at": "at",
    "seconds_one": "second",
    "seconds_other": "seconds",
    "minutes_one": "minute",
    "minutes_other": "minutes",
    "hours_one": "hour",
    "hours_other": "hours"
  },
  "SearchPage": {
    "SearchResultsFor": "Search results for:",
    "NothingFoundFor": "Nothing found for:",
    "EnterYourSearchTerm": "Enter your search term"
  },
  "MessagesPage": {
    "Messages": "Messages",
    "NoConversations": "No conversations yet",
    "NoMessages": "No messages yet. Say hello!",
    "TypeMessage": "Type a message...",
    "LoadError": "Could not load messages",
    "Unknown": "Unknown user"
  },
  "CommunitiesPage": {
    "Communities": "Communities",
    "Create": "Create",
    "NamePlaceholder": "Community name",
    "DescriptionPlaceholder": "Description (optional)",
    "NoCommunities": "No communities yet. Create the first one!",
    "Members": "members",
    "Open": "Open",
    "Join": "Join",
    "Leave": "Leave",
    "JoinToChat": "Join this community to read and send messages",
    "NoMessages": "No messages yet. Start the conversation!",
    "TypeMessage": "Type a message...",
    "LoadError": "Could not load communities",
    "Unknown": "Unknown user",
    "PrivateLabel": "Private (approval required to join)",
    "Requested": "Requested",
    "RequestToJoin": "Request to join",
    "RequestPending": "Your request is awaiting approval",
    "RequestToChat": "Request to join this community to read and send messages",
    "JoinRequests": "Join requests",
    "Approve": "Approve",
    "Decline": "Decline"
  },
  "FriendsPage": {
    "Friends": "Friends",
    "FindPeople": "Find people",
    "SearchPlaceholder": "Search by name or @id...",
    "NoResults": "No people found",
    "Requests": "Friend requests",
    "Sent": "Sent requests",
    "MyFriends": "My friends",
    "NoFriends": "You have no friends yet. Find people above!",
    "AddFriend": "Add friend",
    "Requested": "Requested",
    "Accept": "Accept",
    "Decline": "Decline",
    "Cancel": "Cancel",
    "Message": "Message",
    "Remove": "Remove"
  },
  "ProfileActions": {
    "Message": "Message",
    "AddFriend": "Add friend",
    "Requested": "Requested",
    "Accept": "Accept",
    "Friends": "Friends ✓"
  }
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/public/locales/en/translation.json"

mkdir -p "frontend/public/locales/ru"
cat > "frontend/public/locales/ru/translation.json" << 'CRYSTAL_EOF_7C2F9A6B'
{
  "SystemMessages": {
    "Error": "Ошибка"
  },
  "Common": {
    "LargeImageError": "❌ Максимальный размер GIF - 2.5MB",
    "UploadingImageError": "❌ Ошибка при загрузке изображения."
  },
  "AccessModal": {
    "SwitchLogIn": "Войти",
    "SwitchSignUp": "Регистрация",
    "InputNameLogIn": "Имя",
    "InputNameSignUp": "Имя",
    "InputErrorNameEmpty": "Введите имя",
    "InputErrorNameMinimumLength": "Минимальная длина имени - 1 символ",
    "InputErrorNameMaximumLength": "Максимальная длина имени - 200 символов",
    "InputErrorIdAlreadyExists": "Этот Id уже существует",
    "InputErrorIdMinimumLength": "Минимальная длина Id - 1 символ",
    "InputErrorIdMaximumLength": "Максимальная длина Id - 35 символов",
    "InputErrorIdMinimumMaximumLengthSymbols": "Минимальная длина id - 1 символ, максимальная - 35, допускаются латинские буквы, цифры, нижние подчеркивания и тире",
    "InputEmail": "* Email",
    "InputErrorEmailEmpty": "Введите email",
    "InputErrorEmailMaximumLength": "Максимальная длина email - 100 символов",
    "InputErrorEmailAlreadyExists": "Этот email уже существует",
    "InputPasswordLogIn": "Пароль",
    "InputPasswordSignUp": "* Пароль",
    "InputErrorPasswordEmpty": "Введите пароль",
    "InputErrorPasswordMinimumMaximumLengthSymbols": "Минимальная длина пароля - 8 символов, максимальная - 50, допускаются латинские буквы, цифры и специальные символы",
    "InputErrorEmailPasswordWrong": "Неверная почта или пароль",
    "InputErrorAcceptTerms": "Необходимо принять условия",
    "Terms": "Я принимаю <1>условия пользовательского соглашения</1>, <2>политику конфиденциальности</2> и <3>политику использования файлов cookies</3>."
  },
  "User": {
    "UserDeleted": "Пользователь удалён"
  },
  "PostCreatePage": {
    "CreatePost": "Создать пост",
    "Text": "Текст",
    "Title": "Заголовок",
    "AddMainImage": "Добавить изображение",
    "ChangeMainImage": "Изменить",
    "DeleteMainImage": "Удалить",
    "Publish": "Опубликовать",
    "Back": "Назад",
    "FailedCreatePost": "Не удалось создать пост."
  },
  "PostEditPage": {
    "EditPost": "Редактирование поста",
    "AddMainImage": "Добавить изображение",
    "Change": "Изменить",
    "Delete": "Удалить",
    "Publish": "Опубликовать",
    "Text": "Текст",
    "Title": "Заголовок",
    "Back": "Назад",
    "FailedSaveChanges": "Не удалось сохранить изменения"
  },
  "UserEditPage": {
    "EditUser": "Редактирование пользователя и настройки",
    "Settings": "Настройки",
    "Interface": "Интерфейс",
    "Privacy": "Конфиденциальность",
    "HideGif": "Скрыть GIF",
    "ShowGif": "Показать GIF",
    "UserName": "Имя",
    "UserBio": "О себе",
    "DeleteAllYourPostsButton": "Удалить все посты",
    "DeleteAllUserPostsButton": "Удалить все посты",
    "DeleteAllYourPosts": "Удалить все посты ? Посты будут удалены без возможности восстановления.",
    "DeleteAllPostsByUser": "Удалить все посты пользователя ? Посты будут удалены без возможности восстановления.",
    "AllPostsDeleted": "Все посты удалены",
    "DeleteAccount": "Удалить аккаунт",
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ? Аккаунт будет удален без возможности восстановления.",
    "DeleteUserAccount": "Удалить аккаунт пользователя",
    "SaveChanges": "Сохранить изменения",
    "Save": "Сохранить",
    "IdErrorMinimumMaximumLengthSymbols": "Минимальная длина id - 1 символ, максимальная - 35, допускаются латинские буквы, цифры, нижние подчеркивания и тире",
    "IdAlreadyExists": "Этот Id уже существует",
    "ChangePassword": "Изменить пароль",
    "Hide": "Скрыть",
    "OldPassword": "Старый пароль",
    "NewPassword": "Новый пароль",
    "OldPasswordIncorrect": "Старый пароль - неверный",
    "PasswordRequirements": "В пароле допускаются латинские буквы, цифры и специальные символы.",
    "PasswordSuccessfullyChanged": "Пароль успешно изменён",
    "Gender": "Пол",
    "Female": "женский",
    "Male": "мужской",
    "Unspecified": "не указан",
    "CustomGender": "Самоопределение",
    "GenderError": "Ошибка обновления пола.",
    "GenderSelectionNotAvailable": "Функция выбора пола недоступна",
    "HideGender": "Скрыть пол",
    "ShowGender": "Показать пол"
  },
  "CookiesBanner": {
    "Text": "Этот сайт использует файлы cookies. Нажимая кнопку 'Принять' или продолжая пользоваться сайтом, вы соглашаетесь на использование файлов cookies.",
    "ButtonMoreDetails": "Подробнее",
    "ButtonAccept": "Принять"
  },
  "SideMenuDesktop": {
    "MyProfile": "Мой профиль",
    "Messages": "Сообщения",
    "Friends": "Друзья",
    "Communities": "Сообщества",
    "Photo": "Фото",
    "Video": "Видео",
    "Likes": "Нравится",
    "Settings": "Настройки",
    "Bookmarks": "Закладки",
    "AboutCrystal": "О Crystal",
    "Agreements": "Соглашения",
    "Help": "Помощь"
  },
  "SideMenuMobile": {
    "MyProfile": "Мой профиль",
    "Messages": "Сообщения",
    "Friends": "Друзья",
    "Communities": "Сообщества",
    "Photo": "Фото",
    "Video": "Видео",
    "Likes": "Нравится",
    "Bookmarks": "Закладки",
    "AboutCrystal": "О Crystal",
    "Agreements": "Соглашения",
    "Help": "Помощь"
  },
  "CurrentTopics": {
    "CurrentTopics": "Актуальные темы",
    "ShowMore": "Посмотреть еще",
    "Post": "Пост",
    "PostsAverage": "Поста",
    "Posts": "постов",
    "key_one": "пост",
    "key_few": "поста",
    "key_many": "постов"
  },
  "RecommendedUsers": {
    "YouMightLike": "Вам может понравиться",
    "Subscribe": "Подписаться",
    "ShowMore": "Посмотреть еще"
  },
  "OptionsMenuGuest": {
    "AboutCrystal": "О CRYSTAL",
    "Agreements": "Соглашения",
    "Help": "Помощь"
  },
  "PostSourceMenu": {
    "Subscriptions": "Подписки",
    "Preferences": "Предпочтения",
    "Mine": "Мои",
    "World": "Мир"
  },
  "OptionsMenuUser": {
    "MyProfile": "Мой профиль",
    "Settings": "Настройки",
    "Agreements": "Соглашения",
    "Help": "Помощь",
    "Exit": "Выход",
    "LogOut": "Выйти из аккаунта ?"
  },
  "PostPreview": {
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ?",
    "DeleteAllUserPostsQuestion": "Удалить все посты пользователя ?",
    "DeletePostQuestion": "Удалить пост ?",
    "UserDeleted": "Пользователь удален",
    "EditPost": "Редактировать",
    "DeletePost": "Удалить",
    "DeleteAllUserPosts": "Удалить все посты пользователя",
    "DeleteUser": "Удалить пользователя",
    "add": "доб",
    "upd": "обн"
  },
  "FullPostPage": {
    "DeleteAccountQuestion": "Удалить аккаунт пользователя ?",
    "DeleteAllUserPostsQuestion": "Удалить все посты пользователя ?",
    "DeletePostQuestion": "Удалить пост ?",
    "UserDeleted": "Пользователь удален",
    "EditPost": "Редактировать",
    "DeletePost": "Удалить",
    "DeleteAllUserPosts": "Удалить все посты пользователя",
    "DeleteUser": "Удалить пользователя",
    "add": "доб",
    "upd": "обн"
  },
  "UserInformation": {
    "EditUser": "Редактировать",
    "FailedDeleteAvatar": "❌ Не удалось удалить аватар",
    "FailedDeleteBanner": "❌ Не удалось удалить баннер",
    "ShowMore": "Подробнее",
    "Hide": "Скрыть"
  },
  "LikesPage": {
    "LikedPosts": "Нравится",
    "NolikedPosts": "Нет понравившихся постов"
  },
  "MoreAboutUserModal": {
    "DetailedInformation": "Подробная информация",
    "Gender": "Пол",
    "Female": "женский",
    "Male": "мужской",
    "Unspecified": "не указан",
    "Registration": "Дата регистрации",
    "Update": "Обновление"
  },
  "UseFormattedLastSeenDateShort": {
    "seconds": "с",
    "minutes": "мин",
    "hours": "ч",
    "days": "д",
    "months": "мес",
    "key_one": "г",
    "key_few": "г",
    "key_many": "л",
    "key_other": "л"
  },
  "UseFormattedLastSeenDate": {
    "prefix_male": "Заходил",
    "prefix_female": "Заходила",
    "prefix_unspecified": "Заходил(а)",
    "ago": "назад",
    "yesterday": "вчера",
    "at": "в",
    "seconds_one": "секунду",
    "seconds_few": "секунды",
    "seconds_many": "секунд",
    "minutes_one": "минуту",
    "minutes_few": "минуты",
    "minutes_many": "минут",
    "hours_one": "час",
    "hours_few": "часа",
    "hours_many": "часов"
  },
  "SearchPage": {
    "SearchResultsFor": "Результаты поиска для:",
    "NothingFoundFor": "Ничего не найдено для:",
    "EnterYourSearchTerm": "Введите запрос для поиска"
  },
  "MessagesPage": {
    "Messages": "Сообщения",
    "NoConversations": "Пока нет диалогов",
    "NoMessages": "Сообщений пока нет. Поздоровайтесь!",
    "TypeMessage": "Введите сообщение...",
    "LoadError": "Не удалось загрузить сообщения",
    "Unknown": "Неизвестный пользователь"
  },
  "CommunitiesPage": {
    "Communities": "Сообщества",
    "Create": "Создать",
    "NamePlaceholder": "Название сообщества",
    "DescriptionPlaceholder": "Описание (необязательно)",
    "NoCommunities": "Пока нет сообществ. Создайте первое!",
    "Members": "участников",
    "Open": "Открыть",
    "Join": "Вступить",
    "Leave": "Покинуть",
    "JoinToChat": "Вступите в сообщество, чтобы читать и отправлять сообщения",
    "NoMessages": "Сообщений пока нет. Начните общение!",
    "TypeMessage": "Введите сообщение...",
    "LoadError": "Не удалось загрузить сообщества",
    "Unknown": "Неизвестный пользователь",
    "PrivateLabel": "Приватное (нужно одобрение для вступления)",
    "Requested": "Заявка отправлена",
    "RequestToJoin": "Подать заявку",
    "RequestPending": "Ваша заявка ожидает одобрения",
    "RequestToChat": "Подайте заявку на вступление, чтобы читать и отправлять сообщения",
    "JoinRequests": "Заявки на вступление",
    "Approve": "Принять",
    "Decline": "Отклонить"
  },
  "FriendsPage": {
    "Friends": "Друзья",
    "FindPeople": "Найти людей",
    "SearchPlaceholder": "Поиск по имени или @id...",
    "NoResults": "Никого не найдено",
    "Requests": "Заявки в друзья",
    "Sent": "Отправленные заявки",
    "MyFriends": "Мои друзья",
    "NoFriends": "У вас пока нет друзей. Найдите людей выше!",
    "AddFriend": "Добавить",
    "Requested": "Отправлено",
    "Accept": "Принять",
    "Decline": "Отклонить",
    "Cancel": "Отменить",
    "Message": "Написать",
    "Remove": "Удалить"
  },
  "ProfileActions": {
    "Message": "Написать",
    "AddFriend": "Добавить",
    "Requested": "Заявка отправлена",
    "Accept": "Принять",
    "Friends": "В друзьях ✓"
  }
}
CRYSTAL_EOF_7C2F9A6B
echo "  wrote frontend/public/locales/ru/translation.json"

echo ""
echo "Done. Social features written (friends, search, community requests, profile buttons)."
