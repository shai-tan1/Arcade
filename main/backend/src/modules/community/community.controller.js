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
