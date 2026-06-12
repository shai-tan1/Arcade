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
