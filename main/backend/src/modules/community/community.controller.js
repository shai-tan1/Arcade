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

/* -----------------------------------------------------------
   GET /communities
   List every community with member count and whether the
   current user is already a member.
----------------------------------------------------------- */
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
                    membersCount: { $size: '$members' },
                    isMember: { $in: [myId, '$members'] }
                }
            }
        ]).toArray();

        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   POST /communities
   Body: { name, description? }
   Creator automatically becomes the first member.
----------------------------------------------------------- */
export const createCommunity = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
        const description = typeof req.body.description === 'string'
            ? req.body.description.trim()
            : '';

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
            creatorId: myId,
            members: [myId],
            createdAt: new Date()
        };

        const result = await communities().insertOne(doc);
        res.status(201).json({ _id: result.insertedId, ...doc });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   GET /communities/:communityId
   Single community with populated member list.
----------------------------------------------------------- */
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
                    isMember: {
                        $in: [myId, { $map: { input: '$members', as: 'm', in: '$$m._id' } }]
                    }
                }
            }
        ]).toArray();

        if (!found.length) {
            return res.status(404).json({ message: 'Community not found' });
        }

        res.status(200).json(found[0]);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   POST /communities/:communityId/join
----------------------------------------------------------- */
export const joinCommunity = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);

        const result = await communities().updateOne(
            { _id: new ObjectId(communityId) },
            { $addToSet: { members: myId } }
        );

        if (result.matchedCount === 0) {
            return res.status(404).json({ message: 'Community not found' });
        }

        res.status(200).json({ message: 'Joined' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   POST /communities/:communityId/leave
----------------------------------------------------------- */
export const leaveCommunity = async (req, res) => {
    try {
        const { communityId } = req.params;
        if (!ObjectId.isValid(communityId)) {
            return res.status(400).json({ message: 'Invalid community id' });
        }
        const myId = new ObjectId(req.userId._id);

        const result = await communities().updateOne(
            { _id: new ObjectId(communityId) },
            { $pull: { members: myId } }
        );

        if (result.matchedCount === 0) {
            return res.status(404).json({ message: 'Community not found' });
        }

        res.status(200).json({ message: 'Left' });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   GET /communities/:communityId/messages
   Only members may read the room chat.
----------------------------------------------------------- */
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

/* -----------------------------------------------------------
   POST /communities/:communityId/messages
   Body: { text }. Only members may post. Notifies all members.
----------------------------------------------------------- */
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

        // Realtime: notify every member to refresh this room's chat.
        emitToUsers(
            community.members.map((m) => m.toString()),
            { type: 'community:message', communityId }
        );

        res.status(201).json(created);
    } catch (error) {
        handleServerError(res, error);
    }
};
