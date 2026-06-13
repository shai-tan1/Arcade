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
