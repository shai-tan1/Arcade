// src/modules/admin/admin.routes.js

import express from 'express';
import { auth } from '../auth/index.js';
import * as controller from './admin.controller.js';

const router = express.Router();

router.get('/me', auth, controller.getMe);
router.get('/moderators', auth, controller.listModerators);
router.post('/moderators', auth, controller.addModerator);
router.delete('/moderators/:userId', auth, controller.removeModerator);

export default router;
