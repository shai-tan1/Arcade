// src/modules/forum/forums.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import * as controller from './forum.controller.js';

const router = express.Router();

// topics list + create
router.get('/', auth, controller.listTopics);
router.post('/', auth, controller.createTopic);

// single topic (literal /topic/ avoids any :id collisions)
router.get('/topic/:id', auth, controller.getTopic);
router.patch('/topic/:id', auth, controller.updateTopic);
router.delete('/topic/:id', auth, controller.deleteTopic);
router.post('/topic/:id/vote', auth, controller.voteTopic);

// comments under a topic
router.get('/topic/:id/comments', auth, controller.listComments);
router.post('/topic/:id/comments', auth, controller.createComment);

// single comment actions (literal /comment/)
router.patch('/comment/:commentId', auth, controller.updateComment);
router.delete('/comment/:commentId', auth, controller.deleteComment);
router.post('/comment/:commentId/vote', auth, controller.voteComment);

export default router;
