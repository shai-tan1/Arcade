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
