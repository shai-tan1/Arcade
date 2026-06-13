#!/usr/bin/env bash
# Repairs the Messages + Communities feature files for crystal-v2.0.
# Run from the repo "main/" directory:  bash apply-crystal-changes.sh
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then
  echo "ERROR: run this from ~/crystal-v2.0/main (the folder containing backend/ and frontend/)"; exit 1
fi

mkdir -p "backend/src/modules/message"
cat > "backend/src/modules/message/message.schema.js" << 'CRYSTAL_EOF_9F3A2B7C'
// src/modules/message/message.schema.js

export const MESSAGE_SCHEMA = {
    bsonType: 'object',
    required: ['senderId', 'receiverId', 'text', 'createdAt', 'read'],
    properties: {
        senderId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        receiverId: {
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
        },
        read: {
            bsonType: 'bool',
            description: 'must be a boolean and is required'
        }
    }
};

export const MESSAGE_INDEXES = [
    // Fast lookup of a conversation between two specific users.
    { key: { senderId: 1, receiverId: 1 } },
    // Fast time-ordering of chat history.
    { key: { createdAt: 1 } },
    // Fast unread counting for the receiver.
    { key: { receiverId: 1, read: 1 } }
];
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/message/message.schema.js"

mkdir -p "backend/src/modules/message"
cat > "backend/src/modules/message/message.controller.js" << 'CRYSTAL_EOF_9F3A2B7C'
// src/modules/message/message.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';
import { emitToUsers } from '../../core/engine/web/websocket.js';

const messages = () => getDB().collection('messages');
const users = () => getDB().collection('users');

const COLLATION_OPTIONS = { collation: { locale: 'en', strength: 2 } };

// Public, safe-to-expose fields of a user (no email / passwordHash).
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

/* -----------------------------------------------------------
   GET /messages
   List of conversations for the current user.
   Returns the other participant, the last message and unread count.
----------------------------------------------------------- */
export const getConversations = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const conversations = await messages().aggregate([
            { $match: { $or: [{ senderId: myId }, { receiverId: myId }] } },
            { $sort: { createdAt: -1 } },
            {
                $addFields: {
                    otherUser: {
                        $cond: [{ $eq: ['$senderId', myId] }, '$receiverId', '$senderId']
                    }
                }
            },
            {
                $group: {
                    _id: '$otherUser',
                    lastMessage: { $first: '$$ROOT' },
                    unreadCount: {
                        $sum: {
                            $cond: [
                                { $and: [{ $eq: ['$receiverId', myId] }, { $eq: ['$read', false] }] },
                                1,
                                0
                            ]
                        }
                    }
                }
            },
            {
                $lookup: {
                    from: 'users',
                    localField: '_id',
                    foreignField: '_id',
                    as: 'user',
                    pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
                }
            },
            { $unwind: { path: '$user', preserveNullAndEmptyArrays: true } },
            { $sort: { 'lastMessage.createdAt': -1 } },
            {
                $project: {
                    _id: 0,
                    user: 1,
                    unreadCount: 1,
                    lastMessage: {
                        text: '$lastMessage.text',
                        createdAt: '$lastMessage.createdAt',
                        senderId: '$lastMessage.senderId'
                    }
                }
            }
        ]).toArray();

        res.status(200).json(conversations);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   GET /messages/:userId
   Full conversation with one user (param is that user's customId).
   Marks messages received from them as read.
----------------------------------------------------------- */
export const getConversation = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);

        const otherUser = await users().findOne(
            { customId: req.params.userId },
            { projection: USER_PUBLIC_PROJECTION, ...COLLATION_OPTIONS }
        );

        if (!otherUser) {
            return res.status(404).json({ message: 'User not found' });
        }

        const otherId = otherUser._id;

        // Mark everything they sent me as read.
        await messages().updateMany(
            { senderId: otherId, receiverId: myId, read: false },
            { $set: { read: true } }
        );

        const chatHistory = await messages().find({
            $or: [
                { senderId: myId, receiverId: otherId },
                { senderId: otherId, receiverId: myId }
            ]
        }).sort({ createdAt: 1 }).toArray();

        res.status(200).json({ user: otherUser, messages: chatHistory });
    } catch (error) {
        handleServerError(res, error);
    }
};

/* -----------------------------------------------------------
   POST /messages
   Body: { receiverId, text }  (receiverId = the other user's _id)
   Persists the message and notifies both participants over WebSocket.
----------------------------------------------------------- */
export const sendMessage = async (req, res) => {
    try {
        const senderId = new ObjectId(req.userId._id);
        const { receiverId, text } = req.body;

        if (!receiverId || !ObjectId.isValid(receiverId)) {
            return res.status(400).json({ message: 'A valid receiverId is required' });
        }

        const trimmed = typeof text === 'string' ? text.trim() : '';
        if (!trimmed) {
            return res.status(400).json({ message: 'Message text is required' });
        }
        if (trimmed.length > MAX_TEXT_LENGTH) {
            return res.status(400).json({ message: `Message is too long (max ${MAX_TEXT_LENGTH})` });
        }

        const receiverObjectId = new ObjectId(receiverId);

        // Make sure the recipient exists.
        const receiver = await users().findOne(
            { _id: receiverObjectId },
            { projection: { _id: 1 } }
        );
        if (!receiver) {
            return res.status(404).json({ message: 'Recipient not found' });
        }

        const newMessage = {
            senderId,
            receiverId: receiverObjectId,
            text: trimmed,
            createdAt: new Date(),
            read: false
        };

        const result = await messages().insertOne(newMessage);
        const created = { _id: result.insertedId, ...newMessage };

        // Realtime: tell both clients to refresh their message data.
        emitToUsers([req.userId._id, receiverId], {
            type: 'message:new',
            message: created
        });

        res.status(201).json(created);
    } catch (error) {
        handleServerError(res, error);
    }
};
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/message/message.controller.js"

mkdir -p "backend/src/modules/message"
cat > "backend/src/modules/message/messages.routes.js" << 'CRYSTAL_EOF_9F3A2B7C'
// src/modules/message/messages.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import {
    getConversations,
    getConversation,
    sendMessage
} from './message.controller.js';

const router = express.Router();

// list of conversations
router.get('/', auth, getConversations);

// send a message
router.post('/', auth, sendMessage);

// full conversation with one user (param = that user's customId)
router.get('/:userId', auth, getConversation);

export default router;
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/message/messages.routes.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/community.schema.js" << 'CRYSTAL_EOF_9F3A2B7C'
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
        creatorId: {
            bsonType: 'objectId',
            description: 'must be an objectId and is required'
        },
        members: {
            bsonType: 'array',
            items: { bsonType: 'objectId' },
            description: 'array of member objectIds and is required'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/community/community.schema.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/community.controller.js" << 'CRYSTAL_EOF_9F3A2B7C'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/community/community.controller.js"

mkdir -p "backend/src/modules/community"
cat > "backend/src/modules/community/communities.routes.js" << 'CRYSTAL_EOF_9F3A2B7C'
// src/modules/community/communities.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import {
    getCommunities,
    createCommunity,
    getCommunity,
    joinCommunity,
    leaveCommunity,
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

// room chat
router.get('/:communityId/messages', auth, getCommunityMessages);
router.post('/:communityId/messages', auth, sendCommunityMessage);

export default router;
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/modules/community/communities.routes.js"

mkdir -p "backend/src/core/engine/web"
cat > "backend/src/core/engine/web/websocket.js" << 'CRYSTAL_EOF_9F3A2B7C'
// websocket.js
import { WebSocketServer, WebSocket } from 'ws';
import jwt from 'jsonwebtoken';
import { ObjectId } from 'mongodb';
import { getDB } from '../../../core/engine/db/connectDB.js';

import { JWT_SECRET_KEY } from '../../../shared/constants/index.js';

// get collection 'users'
const users = () => getDB().collection('users');

// Module-level reference to the running WebSocket server.
// Set inside initWebSocket() so controllers can push events to clients.
let wssInstance = null;

/**
 * Send a JSON payload to every open socket that belongs to a given user.
 * A user can have several tabs open, so all of their sockets receive it.
 * @param {string} userId
 * @param {object} data
 */
export function emitToUser(userId, data) {
  if (!wssInstance) return;
  const targetId = String(userId);
  const payload = JSON.stringify(data);
  wssInstance.clients.forEach((client) => {
    if (
      client.readyState === WebSocket.OPEN &&
      String(client.userId) === targetId
    ) {
      client.send(payload);
    }
  });
}

/**
 * Send a JSON payload to several users at once (deduplicated).
 * @param {Array<string>} userIds
 * @param {object} data
 */
export function emitToUsers(userIds = [], data) {
  if (!wssInstance) return;
  const unique = [...new Set(userIds.map(String))];
  unique.forEach((id) => emitToUser(id, data));
}

// helper function for ID conversion
const toObjectId = (id) => (id instanceof ObjectId ? id : new ObjectId(id));

export async function initWebSocket(server) {
  // Resetting the status (on isOnline: false) for all users when the server starts
  try {
    console.log('WebSocket: Resetting the status (on isOnline: false) for all users');
    // Add bypassDocumentValidation: true for bulk reset
    await users().updateMany(
      { 'status.isOnline': true },
      {
        $set: {
          'status.isOnline': false,
          'status.activeConnections': 0,
          'status.activeTabs': [],
        },
        $currentDate: { 'status.lastSeen': true }
      },
      { collation: { locale: 'en', strength: 2 }, bypassDocumentValidation: true }
    );
  } catch (error) {
    console.error('WebSocket: Error resetting status:', error);
  }
// /Resetting the status (on isOnline: false) for all users when the server starts

  const wss = new WebSocketServer({ server });
  wssInstance = wss;

  async function verifyToken(token) {
    try {
      const decoded = jwt.verify(token, JWT_SECRET_KEY);
      return decoded._id;
    } catch (err) {
      return null;
    }
  }

  /* -----------------------------------------------------------
  ## Status and Activity Functions
  ----------------------------------------------------------- */

  // Offline control by timeout/visibility (5 seconds)
  async function updateUserActivity(userId, tabId, token) {
    try {
      const userIdObject = toObjectId(userId);
      const verifiedUserId = await verifyToken(token);
      if (!verifiedUserId || verifiedUserId !== userId) return false;

      // 5 second timeout for throttling
      const fiveSecondsAgo = new Date(Date.now() - 5 * 1000);

      const user = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const userStatus = user?.status || {};
      const activeTabs = userStatus.activeTabs || [];

      // SPAM FIX 1: If there are no active tabs (after Logout/Heartbeat), ignore Ping.
      if (activeTabs.length === 0) {
        return true;
      }

      const currentTab = activeTabs.find(tab => tab.tabId === tabId);

      // offline logic by invisibility (heartbeat timeout)
      if (user && currentTab && !currentTab.isVisible) {
        if (user.status?.isOnline === true) {

          // Removing a tab and setting isOnline: false in one request
          // Add bypassDocumentValidation: true for a complex operation
          const result = await users().findOneAndUpdate(
            { _id: userIdObject, 'status.isOnline': true },
            {
              $set: { 'status.isOnline': false, 'status.activeConnections': 0 },
              $currentDate: { 'status.lastSeen': true },
              $pull: { 'status.activeTabs': { tabId } }
            },
            { returnDocument: 'after', bypassDocumentValidation: true }
          );

          if (result?.value?.status?.isOnline === false) {
            broadcast({ type: 'user:offline', userId });
            console.log(`WebSocket: Set isOnline: false (due to timeout/invisibility) for userId ${userId}, tabId ${tabId}`);
          } else {
            // If couldn't set it offline (it means it was already offline) - just delete the tab
            console.log(`WebSocket: Skipping the re-setting of isOnline: false for userId ${userId}, tabId ${tabId} (the status is already OFF).`);
            await users().updateOne(
              { _id: userIdObject },
              { $pull: { 'status.activeTabs': { tabId } } }
            );
          }
          return true;
        }
      }

      // 2. Throttling logic (updating lastSeen and broadcast 'online')
      if (user && currentTab) {
        const result = await users().findOneAndUpdate(
          {
            _id: userIdObject,
            $or: [{ 'status.lastSeen': { $lt: fiveSecondsAgo } }, { 'status.lastSeen': null }],
          },
          {
            $set: { 'status.isOnline': true },
            $currentDate: { 'status.lastSeen': true }
          },
          { returnDocument: 'after' }
        );

        if (result?.value) {
          broadcast({ type: 'user:online', userId });
          console.log(`WebSocket: Activity updated for userId ${userId} (Broadcast ON)`);
        }
      }
      return true;
    } catch (error) {
      console.error('WebSocket: Error updating activity:', error);
      return false;
    }
  }

  // Function to increase 'activeConnections' and add a tab (isOnline: true)
  async function incrementConnections(userId, tabId, token) {
    try {
      const userIdObject = toObjectId(userId);
      const verifiedUserId = await verifyToken(token);
      if (!verifiedUserId || verifiedUserId !== userId) return false;

      console.log(`WebSocket: Increase activeConnections for userId ${userId}, tabId ${tabId}`);

      const user = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const activeTabs = user?.status?.activeTabs || [];

      if (user && activeTabs.some((tab) => tab.tabId === tabId)) {
        // The tab exists: increase the counter and make it visible
        await users().findOneAndUpdate(
          { _id: userIdObject, 'status.activeTabs.tabId': tabId },
          {
            // we update isonline and lastseen if we become visible
            $set: { 'status.activeTabs.$[tab].isVisible': true, 'status.isOnline': true },
            $inc: { 'status.activeConnections': 1 },
            $currentDate: { 'status.lastSeen': true },
          },
          { returnDocument: 'after', arrayFilters: [{ 'tab.tabId': tabId }] }
        );
        broadcast({ type: 'user:online', userId });
      } else {
        // New tab: adding, increasing the counter
        await users().findOneAndUpdate(
          { _id: userIdObject },
          {
            $addToSet: { 'status.activeTabs': { tabId, isVisible: true } },
            $inc: { 'status.activeConnections': 1 },
            // Update isOnline and lastSeen when connecting again
            $set: { 'status.isOnline': true },
            $currentDate: { 'status.lastSeen': true },
          },
          { returnDocument: 'after' } // upsert: true removed
        );
        broadcast({ type: 'user:online', userId });
      }
      return true;
    } catch (error) {
      console.error('WebSocket: Error increasing activeConnections:', error);
      return false;
    }
  }

  // marks the tab as invisible without touching the counter
  async function markTabHidden(userId, tabId) {
    try {
      const userIdObject = toObjectId(userId);
      await users().updateOne(
        { _id: userIdObject, 'status.activeTabs.tabId': tabId },
        { $set: { 'status.activeTabs.$[tab].isVisible': false } },
        { arrayFilters: [{ 'tab.tabId': tabId }] }
      );
      console.log(`[HIDDEN] Tab ${tabId} for userId ${userId} marked as invisible.`);
    } catch (error) {
      console.error('WebSocket: Error when marking tab as hidden:', error);
    }
  }

  // decrementconnections function (exclusively for broken/closed/timeout)
  async function decrementConnections(userId, tabId, removeTab = false, isLogout = false, onComplete = () => { }) {
    const userIdObject = toObjectId(userId);
    console.log(`[DECREMENT] 1. Start for userId ${userId}, tabId ${tabId}, removeTab: ${removeTab}, isLogout: ${isLogout}`);

    try {
      if (isLogout) {
        // scenario 1: instant logout
        // Add bypassDocumentValidation: true for bulk reset
        await users().updateOne(
          { _id: userIdObject },
          {
            $set: { 'status.activeTabs': [], 'status.activeConnections': 0, 'status.isOnline': false },
            $currentDate: { 'status.lastSeen': true }
          },
          { bypassDocumentValidation: true }
        );
        broadcast({ type: 'user:offline', userId });
        console.log(`[DECREMENT] 2. SUCCESS: User ${userId} came out (Logout).`);
        return onComplete();
      }

      // Ignore if not closing/breaking
      if (!removeTab) {
        console.log(`[DECREMENT] We skip the operation. removeTab: false.`);
        return onComplete();
      }

      // 1. Read the current state to safely decrement the counter
      const userDocBeforePull = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const currentConnections = userDocBeforePull?.status?.activeConnections || 0;
      const newConnections = Math.max(0, currentConnections - 1); // never go into the minus

      // 2. Atomically remove the tab and install a new counter
      await users().updateOne(
        { _id: userIdObject },
        {
          $pull: { 'status.activeTabs': { tabId } },
          $set: { 'status.activeConnections': newConnections }, // Setting a safe value
          $currentDate: { 'status.lastSeen': true }
        },
        { bypassDocumentValidation: true } // Bypassing validation for complex $pull + $set operations
      );
      console.log(`[DECREMENT] 2. The tab is removed and activeConnections is set to ${newConnections}.`);


      // 3. Loading the current status for a final check of the activeTabs length
      const userDoc = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const updatedStatus = userDoc?.status;
      // Use the actual length of the array, not just the activeConnections counter
      const activeTabsCount = updatedStatus?.activeTabs?.length || 0;
      console.log(`[DECREMENT] 3. Current activeTabs.length: ${activeTabsCount}`);


      // 4. final offline atomic check (only if array is empty)
      if (updatedStatus && updatedStatus.isOnline === true && activeTabsCount === 0) {
        const finalCheckResult = await users().updateOne(
          {
            _id: userIdObject,
            'status.isOnline': true,
            'status.activeTabs': { $size: 0 }, // Check that the array is empty
          },
          {
            $set: {
              'status.isOnline': false,
              'status.activeConnections': 0, // Synchronize the counter to 0
            },
            $currentDate: { 'status.lastSeen': true }
          }
        );

        if (finalCheckResult.modifiedCount > 0) {
          console.log(`[DECREMENT] 4. SUCCESS: OFFLINE TRIGGER (activeTabs=0) for userId ${userId}`);
          broadcast({ type: 'user:offline', userId });
        } else {
          console.log(`[DECREMENT] 4. Offline Check: Status remains TRUE or there are still tabs. modifiedCount=0`);
        }
      } else {
        console.log(`[DECREMENT] 4. Offline Check: User is online or has active tabs (${activeTabsCount}). Skipping the trigger.`);
      }

    } catch (error) {
      console.error('WebSocket: Error decreasing activeConnections:', error);
    }

    onComplete();
  }
  // /decrementconnections function (exclusively for broken/closed/timeout)

  /* -----------------------------------------------------------
  ## Connection management
  ----------------------------------------------------------- */

  wss.on('connection', (ws, req) => {
    console.log('WebSocket: Trying a new connection');
    const cookieHeader = req.headers.cookie;
    let token = null;
    if (cookieHeader) {
      const cookies = cookieHeader.split(';').reduce((acc, cookie) => {
        const [key, value] = cookie.trim().split('=');
        acc[key] = value;
        return acc;
      }, {});
      token = cookies.token;
    }

    if (!token) {
      ws.close(1008, 'Token not provided');
      return;
    }

    try {
      const decoded = jwt.verify(token, JWT_SECRET_KEY);
      ws.userId = decoded._id;
      ws.token = token;

      // Clearing old invisible tabs when connecting again
      cleanupOldTabs(ws.userId);

      ws.isAlive = true;
      ws.on('pong', async () => {
        ws.isAlive = true;
        if (ws.tabId) {
          // Processing Ping from the client
          await updateUserActivity(ws.userId, ws.tabId, ws.token);
        }
      });

      ws.on('message', async (message) => {
        try {
          const data = message.toString();
          if (data === 'ping') {
            ws.send('pong');
            return;
          }
          const parsed = JSON.parse(data);

          if (parsed.type === 'visibility' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            if (parsed.status === 'visible') {
              await incrementConnections(ws.userId, parsed.tabId, ws.token);
            } else if (parsed.status === 'hidden') {
              // Collapse: Just mark it as invisible without touching the counter
              await markTabHidden(ws.userId, parsed.tabId);
            }
          } else if (parsed.type === 'activity' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            await updateUserActivity(ws.userId, parsed.tabId, ws.token);
          } else if (parsed.type === 'logout' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            await decrementConnections(ws.userId, ws.tabId, true, true, () => {
              wss.clients.forEach((client) => {
                if (client !== ws && client.userId === ws.userId && client.readyState === WebSocket.OPEN) {
                  client.close(1000, 'The user has logged out');
                }
              });
              ws.close(1000, 'The user has logged out');
            });
          }
        } catch (error) {
          console.error('WebSocket: Error processing message:', error);
        }
      });

      ws.on('close', async () => {
        console.log(`WebSocket: The connection was closed. userId: ${ws.userId}, tabId: ${ws.tabId}`);
        if (ws.tabId) {
          // Connection lost (browser closed) -> delete tab
          await decrementConnections(ws.userId, ws.tabId, true);
        } else {
          console.log('WebSocket: Failed to determine tabId on close, decrementConnections operation skipped.');
        }
      });
    } catch (err) {
      ws.close(1008, 'Invalid token');
    }
  });

  // Checking client activity (Heartbeat)
  setInterval(() => {
    wss.clients.forEach(async (ws) => {
      if (!ws.isAlive && ws.tabId) {
        // If the client does not respond to ping (30 seconds), we consider it dead.
        console.log(`WebSocket: Heartbeat timeout for userId ${ws.userId}, tabId ${ws.tabId}.`);
        await decrementConnections(ws.userId, ws.tabId, true, false, () => {
          // Call ws.terminate() only after the MongoDB operation completes
          return ws.terminate();
        });
      }
      ws.isAlive = false;
      ws.ping();
    });
  }, 30000); // <-- heartbeat timeout 30 seconds

  function broadcast(data) {
    wss.clients.forEach((client) => {
      if (client.readyState === client.OPEN) {
        client.send(JSON.stringify(data));
      }
    });
  }

  // Clearing old tabs (at startup/upon connection)
  async function cleanupOldTabs(userId) {
    try {
      const userIdObject = toObjectId(userId);
      console.log(`WebSocket: Clearing old tabs for userId ${userId}`);

      // remove all invisible tabs and reset the activeConnections counter to 0.
      // added bypassdocumentvalidation: true
      const result = await users().findOneAndUpdate(
        { _id: userIdObject },
        {
          $pull: { 'status.activeTabs': { isVisible: false } },
          $set: { 'status.activeConnections': 0 },
          $currentDate: { 'status.lastSeen': true }
        },
        { returnDocument: 'after', bypassDocumentValidation: true } // upsert: true removed
      );

      if (result?.value) {
        const activeTabs = result.value.status?.activeTabs || [];
        console.log(`WebSocket: Cleared invisible tabs for userId ${userId}, activeTabs: ${activeTabs.length}`);
        // When cleaning, set it to offline if there are no visible tabs.
        if (!activeTabs.some((tab) => tab.isVisible)) {
          await users().updateOne(
            { _id: userIdObject },
            {
              $set: { 'status.isOnline': false },
              $currentDate: { 'status.lastSeen': true }
            },
            {}
          );
          console.log(`WebSocket: Set isOnline: false for userId ${userId} after clearing tabs`);
          broadcast({ type: 'user:offline', userId });
        }
      }
    } catch (error) {
      console.error('WebSocket: Error clearing old tabs:', error);
    }
  }

}
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/core/engine/web/websocket.js"

mkdir -p "backend/src/core/engine/db"
cat > "backend/src/core/engine/db/initializeCollections.js" << 'CRYSTAL_EOF_9F3A2B7C'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote backend/src/core/engine/db/initializeCollections.js"

mkdir -p "frontend/src/pages/MessagesPage"
cat > "frontend/src/pages/MessagesPage/MessagesPage.jsx" << 'CRYSTAL_EOF_9F3A2B7C'
// frontend/src/pages/MessagesPage/MessagesPage.jsx

import { useEffect, useRef, useState } from 'react';
import { useParams, Link, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon, EnterIcon } from '../../shared/ui';

import styles from './MessagesPage.module.css';

function formatTime(value) {
  if (!value) return '';
  const date = new Date(value);
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
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

/* ----------------------------- Conversation list ----------------------------- */
function ConversationList() {
  const { t } = useTranslation();

  const { data, isPending, isError } = useQuery({
    queryKey: ['messages', 'conversations'],
    queryFn: () => httpClient.get('/messages'),
    retry: false
  });

  if (isPending) {
    return (
      <div className={styles.center_loader}>
        <div className={styles.loader}><Loader /></div>
      </div>
    );
  }

  if (isError) {
    return <p className={styles.empty}>{t('MessagesPage.LoadError')}</p>;
  }

  if (!data || data.length === 0) {
    return <p className={styles.empty}>{t('MessagesPage.NoConversations')}</p>;
  }

  return (
    <ul className={styles.conversation_list}>
      {data.map((conv) => (
        <li key={conv.user?._id || Math.random()} className={styles.conversation_item}>
          <Link to={`/messages/${conv.user?.customId}`} className={styles.conversation_link}>
            <div className={styles.avatar_wrap}>
              <Avatar user={conv.user} />
              {conv.user?.status?.isOnline && <span className={styles.online_dot} />}
            </div>
            <div className={styles.conversation_text}>
              <div className={styles.conversation_top}>
                <span className={styles.conversation_name}>{conv.user?.name || t('MessagesPage.Unknown')}</span>
                <span className={styles.conversation_time}>{formatTime(conv.lastMessage?.createdAt)}</span>
              </div>
              <p className={styles.conversation_preview}>{conv.lastMessage?.text}</p>
            </div>
            {conv.unreadCount > 0 && <span className={styles.unread_badge}>{conv.unreadCount}</span>}
          </Link>
        </li>
      ))}
    </ul>
  );
}

/* ----------------------------- Single chat thread ----------------------------- */
function ChatThread({ userId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();

  const [text, setText] = useState('');
  const bottomRef = useRef(null);

  const { data, isPending, isError } = useQuery({
    queryKey: ['messages', 'thread', userId],
    queryFn: () => httpClient.get(`/messages/${userId}`),
    retry: false
  });

  const sendMutation = useMutation({
    mutationFn: (body) => httpClient.post('/messages', body),
    onSuccess: () => {
      setText('');
      queryClient.invalidateQueries({ queryKey: ['messages', 'thread', userId] });
      queryClient.invalidateQueries({ queryKey: ['messages', 'conversations'] });
    }
  });

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [data?.messages?.length]);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed || !data?.user?._id || sendMutation.isPending) return;
    sendMutation.mutate({ receiverId: data.user._id, text: trimmed });
  };

  const handleKeyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSend();
    }
  };

  if (isPending) {
    return (
      <div className={styles.center_loader}>
        <div className={styles.loader}><Loader /></div>
      </div>
    );
  }

  if (isError) {
    return (
      <div className={styles.thread}>
        <div className={styles.thread_header}>
          <button className={styles.back_button} onClick={() => navigate('/messages')}>←</button>
          <span className={styles.conversation_name}>{t('MessagesPage.Unknown')}</span>
        </div>
        <p className={styles.empty}>{t('MessagesPage.LoadError')}</p>
      </div>
    );
  }

  const myId = authorizedUser?._id;

  return (
    <div className={styles.thread}>
      <div className={styles.thread_header}>
        <button className={styles.back_button} onClick={() => navigate('/messages')} aria-label="Back">←</button>
        <div className={styles.avatar_wrap}>
          <Avatar user={data.user} />
          {data.user?.status?.isOnline && <span className={styles.online_dot} />}
        </div>
        <Link to={`/${data.user?.customId}`} className={styles.conversation_name}>{data.user?.name}</Link>
      </div>

      <div className={styles.messages_scroll}>
        {data.messages.length === 0 && (
          <p className={styles.empty}>{t('MessagesPage.NoMessages')}</p>
        )}
        {data.messages.map((message) => {
          const isOwn = String(message.senderId) === String(myId);
          return (
            <div
              key={message._id}
              className={isOwn ? `${styles.bubble} ${styles.bubble_own}` : styles.bubble}
            >
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
          placeholder={t('MessagesPage.TypeMessage')}
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
    </div>
  );
}

/* ----------------------------- Page ----------------------------- */
export function MessagesPage() {
  const { userId } = useParams();
  const { t } = useTranslation();

  return (
    <div className={styles.messages_page}>
      <div className={styles.title}>
        <h1>{t('MessagesPage.Messages')}</h1>
      </div>
      {userId ? <ChatThread userId={userId} /> : <ConversationList />}
    </div>
  );
}
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/MessagesPage/MessagesPage.jsx"

mkdir -p "frontend/src/pages/MessagesPage"
cat > "frontend/src/pages/MessagesPage/MessagesPage.module.css" << 'CRYSTAL_EOF_9F3A2B7C'
.messages_page {
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

.empty {
  text-align: center;
  padding: 40px 20px;
  color: var(--separator_color_global);
}

.center_loader {
  height: 300px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.loader {
  height: 21px;
  width: 21px;
}

/* ---------- conversation list ---------- */
.conversation_list {
  list-style: none;
}

.conversation_item {
  border-bottom: var(--border_global);
}

.conversation_link {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
  text-decoration: none;
  color: var(--color_global);
  transition: var(--transition_background-color_hover_global);
}

.conversation_link:hover {
  background-color: var(--item_hover_global);
}

.conversation_text {
  flex: 1;
  min-width: 0;
}

.conversation_top {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 8px;
}

.conversation_name {
  font-weight: 600;
  color: var(--color_global);
  text-decoration: none;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.conversation_time {
  font-size: 12px;
  color: var(--separator_color_global);
  flex-shrink: 0;
}

.conversation_preview {
  margin-top: 2px;
  font-size: 14px;
  color: var(--separator_color_global);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.unread_badge {
  flex-shrink: 0;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  border-radius: 10px;
  background-color: var(--hashtag_color_global);
  color: #fff;
  font-size: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}

/* ---------- thread ---------- */
.thread {
  display: flex;
  flex-direction: column;
  height: 70vh;
  background-color: var(--filling_background-color_global);
}

.thread_header {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 16px;
  border-bottom: var(--border_global);
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/MessagesPage/MessagesPage.module.css"

mkdir -p "frontend/src/pages/MessagesPage"
cat > "frontend/src/pages/MessagesPage/index.js" << 'CRYSTAL_EOF_9F3A2B7C'
export { MessagesPage } from "./MessagesPage";
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/MessagesPage/index.js"

mkdir -p "frontend/src/pages/CommunitiesPage"
cat > "frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx" << 'CRYSTAL_EOF_9F3A2B7C'
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
    createMutation.mutate({ name: trimmed, description: description.trim() });
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
            ) : (
              <button
                className={styles.join_button}
                onClick={() => joinMutation.mutate(community._id)}
                disabled={joinMutation.isPending}
              >
                {t('CommunitiesPage.Join')}
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
          <p>{t('CommunitiesPage.JoinToChat')}</p>
          <button
            className={styles.join_button}
            onClick={() => joinMutation.mutate()}
            disabled={joinMutation.isPending}
          >
            {t('CommunitiesPage.Join')}
          </button>
        </div>
      ) : (
        <>
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx"

mkdir -p "frontend/src/pages/CommunitiesPage"
cat > "frontend/src/pages/CommunitiesPage/CommunitiesPage.module.css" << 'CRYSTAL_EOF_9F3A2B7C'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/CommunitiesPage/CommunitiesPage.module.css"

mkdir -p "frontend/src/pages/CommunitiesPage"
cat > "frontend/src/pages/CommunitiesPage/index.js" << 'CRYSTAL_EOF_9F3A2B7C'
export { CommunitiesPage } from "./CommunitiesPage";
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/CommunitiesPage/index.js"

mkdir -p "frontend/src/pages"
cat > "frontend/src/pages/index.js" << 'CRYSTAL_EOF_9F3A2B7C'
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
export { NotFoundPage } from "./NotFoundPage";
export { TermsPage } from "./TermsPage";
export { PrivacyPage } from "./PrivacyPage";
export { CookiesPolicyPage } from "./CookiesPolicyPage";
export { AboutCrystalPage } from "./AboutCrystalPage";
export { AgreementsPage } from "./AgreementsPage";
export { HelpPage } from "./HelpPage";
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/pages/index.js"

mkdir -p "frontend/src/app"
cat > "frontend/src/app/App.jsx" << 'CRYSTAL_EOF_9F3A2B7C'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/app/App.jsx"

mkdir -p "frontend/src/widgets/SideMenuDesktop"
cat > "frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx" << 'CRYSTAL_EOF_9F3A2B7C'
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
          <Link to={`/${authorizedUser.customId}`}></Link>
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx"

mkdir -p "frontend/src/shared/hooks/useWebSocket"
cat > "frontend/src/shared/hooks/useWebSocket/useWebSocket.js" << 'CRYSTAL_EOF_9F3A2B7C'
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
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/src/shared/hooks/useWebSocket/useWebSocket.js"

mkdir -p "frontend/public/locales/en"
cat > "frontend/public/locales/en/translation.json" << 'CRYSTAL_EOF_9F3A2B7C'
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
    "Unknown": "Unknown user"
  }
}
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/public/locales/en/translation.json"

mkdir -p "frontend/public/locales/ru"
cat > "frontend/public/locales/ru/translation.json" << 'CRYSTAL_EOF_9F3A2B7C'
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
    "Unknown": "Неизвестный пользователь"
  }
}
CRYSTAL_EOF_9F3A2B7C
echo "  wrote frontend/public/locales/ru/translation.json"

rm -f backend/src/modules/message/message.routes.js
echo "  removed old backend/src/modules/message/message.routes.js (if it existed)"

echo ""
echo "Done. All Messages + Communities files written."
