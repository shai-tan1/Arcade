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
