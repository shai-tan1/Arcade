// src/modules/auth/auth.controller.js

import jwt from "jsonwebtoken";
import bcrypt from "bcrypt";
import { randomBytes } from "node:crypto";

import { getDB } from "../../core/engine/db/connectDB.js";
import { ObjectId } from 'mongodb';

import {
  handleServerError
} from "../../shared/helpers/index.js";
import {
  JWT_SECRET_KEY,
  COOKIE_SECURE_STATUS,
  CREATOR_EMAIL
} from "../../shared/constants/index.js";

const users = () => getDB().collection('users');

// register
export const register = async (req, res) => {
  try {
    const password = req.body.password;
    const salt = await bcrypt.genSalt(10);
    const hash = await bcrypt.hash(password, salt);

    // COLLATION OPTIONS for case-insensitive searching
    const collationOptions = { collation: { locale: "en", strength: 2 } };

    // 1. UNIQUENESS CHECKS
    const emailExists = await users().findOne(
      { email: req.body.email },
      collationOptions
    );

    const customId = req.body.customId;
    if (customId) {
      const customIdExists = await users().findOne(
        { customId: customId },
        collationOptions
      );
      if (customIdExists) {
        return res.status(409).send({ error: 'This Id already exists' });
      }
    }

    if (emailExists) {
      return res.status(409).send({ error: 'This email already exists' });
    }

    // 2. CREATING AND INSERTING A DOCUMENT

    const userDoc = {
      email: req.body.email,
      name: req.body.name,
      customId: customId ? customId : randomBytes(16).toString("hex"),
      creator: (req.body.email === CREATOR_EMAIL),
      passwordHash: hash,
      avatarUri: null,
      bannerUri: null,
      profile: {
        gender: { type: 'unspecified', customValue: '' },
        bio: '',
      },
      settings: {
        interface: { hideGif: false },
        privacy: { hideGender: false },
      },
      status: {
        isOnline: false,
        lastSeen: null,
        activeConnections: 0,
        activeTabs: [],
      },
      createdAt: new Date(),
      updatedAt: new Date(),
    };

    const result = await users().insertOne(userDoc);

    const user = {
      _id: result.insertedId,
      ...userDoc
    };

    const token = jwt.sign(
      {
        _id: user._id,
      },
      JWT_SECRET_KEY
    );
    res.cookie('token', token, { httpOnly: true, secure: COOKIE_SECURE_STATUS, sameSite: 'none', maxAge: 3600 * 1000 * 24 * 365 * 10 });
    res.status(200).send('Registration OK');
  } catch (error) {
    handleServerError(res, error);
  }
};
// /register

// log in
export const logIn = async (req, res) => {
  try {
    const collationOptions = { collation: { locale: "en", strength: 2 } };

    // USER SEARCH (projection replaces {email: 0})
    const user = await users().findOne(
      { email: req.body.email },
      {
        projection: { email: 0 },
        ...collationOptions
      }
    );

    if (!user) {
      return res.status(401).send({ error: 'invalid username or password' });
    }

    // PASSWORD COMPARISON (user._doc.passwordHash is replaced with user.passwordHash)
    const password = await bcrypt.compare(
      req.body.password,
      user.passwordHash
    );

    if (!password) {
      return res.status(401).send({ error: 'invalid username or password' });
    }

    const token = jwt.sign(
      {
        _id: user._id
      },
      JWT_SECRET_KEY
    );
    res.cookie('token', token, { httpOnly: true, secure: COOKIE_SECURE_STATUS, sameSite: 'none', maxAge: 3600 * 1000 * 24 * 365 * 10 });
    res.status(200).send('log in OK');
  } catch (error) {
    handleServerError(res, error);
  }
};
// /log in

// get me
export const getMe = async (req, res) => {
  try {
    // SEARCH BY ID (Replace findById and convert IDs)

    const userIdObjectId = new ObjectId(req.userId._id);

    const user = await users().findOne(
      { _id: userIdObjectId }
    );

    if (!user) {
      return res.status(404).send('User not found');
    }

    // FILTERING (user._doc is replaced with user)
    const { passwordHash, email, ...userData } = user;
    res.status(200).json(userData);
  } catch (error) {
    handleServerError(res, error);
  }
};
// /get me

// log out
export const logOut = async (_, res) => {
  try {
    res.clearCookie('token', { httpOnly: true, secure: COOKIE_SECURE_STATUS, sameSite: 'none' });
    res.status(200).send('log out OK');
  } catch (error) {
    handleServerError(res, error);
  }
};
// log out