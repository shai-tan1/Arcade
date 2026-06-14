// src/modules/admin/admin.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const users = () => getDB().collection('users');

const MOD_PROJECTION = { _id: 1, name: 1, customId: 1, avatarUri: 1, creator: 1, isModerator: 1 };

async function flags(myId) {
    const u = await users().findOne({ _id: myId }, { projection: { creator: 1, isModerator: 1 } });
    return { isCreator: u?.creator === true, isModerator: u?.isModerator === true };
}

// GET /admin/me — any signed-in user; reveals their own privilege level.
export const getMe = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        res.status(200).json(await flags(myId));
    } catch (error) {
        handleServerError(res, error);
    }
};

// GET /admin/moderators — creator only.
export const listModerators = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });
        const list = await users().find({ isModerator: true }).project(MOD_PROJECTION).sort({ name: 1 }).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

// POST /admin/moderators  { customId } — creator only.
export const addModerator = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });

        const customId = typeof req.body?.customId === 'string' ? req.body.customId.trim() : '';
        if (!customId) return res.status(400).json({ message: 'A member username is required' });

        const target = await users().findOne(
            { customId },
            { projection: MOD_PROJECTION, collation: { locale: 'en', strength: 2 } }
        );
        if (!target) return res.status(404).json({ message: 'No member found with that username' });
        if (target.creator) return res.status(400).json({ message: 'The creator already has full access' });
        if (target.isModerator) return res.status(400).json({ message: 'That member is already a moderator' });

        await users().updateOne({ _id: target._id }, { $set: { isModerator: true } });
        res.status(200).json({ ...target, isModerator: true });
    } catch (error) {
        handleServerError(res, error);
    }
};

// DELETE /admin/moderators/:userId — creator only.
export const removeModerator = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const me = await flags(myId);
        if (!me.isCreator) return res.status(403).json({ message: 'Only the creator can manage moderators' });
        const { userId } = req.params;
        if (!ObjectId.isValid(userId)) return res.status(400).json({ message: 'Invalid user id' });
        await users().updateOne({ _id: new ObjectId(userId) }, { $set: { isModerator: false } });
        res.status(200).json({ status: 'removed' });
    } catch (error) {
        handleServerError(res, error);
    }
};
