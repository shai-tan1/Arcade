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
