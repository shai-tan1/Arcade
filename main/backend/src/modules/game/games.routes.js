// src/modules/game/games.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import * as controller from './game.controller.js';

const router = express.Router();

// static GETs first
router.get('/ratings', auth, controller.getRatings);
router.get('/history', auth, controller.getHistory);
router.get('/active', auth, controller.getActiveMatch);
router.get('/challenges', auth, controller.getChallenges);

// matchmaking
router.post('/queue', auth, controller.joinQueue);
router.post('/queue/leave', auth, controller.leaveQueue);
router.post('/challenge', auth, controller.createChallenge);

// match session (define before /:gameType/... )
router.get('/match/:matchId', auth, controller.getMatch);
router.post('/match/:matchId/accept', auth, controller.acceptChallenge);
router.post('/match/:matchId/decline', auth, controller.declineChallenge);
router.post('/match/:matchId/submit', auth, controller.submitAnswer);
router.post('/match/:matchId/forfeit', auth, controller.forfeitMatch);

// per-game leaderboard (param-first; keep last)
router.get('/:gameType/leaderboard', auth, controller.getLeaderboard);

export default router;
