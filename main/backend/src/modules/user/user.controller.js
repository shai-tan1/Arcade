// user.controller.js
import { promises as fsPromises } from 'fs';
import path from 'path';
import bcrypt from "bcrypt";
import {
  handleServerError
} from '../../shared/helpers/index.js';

import { getDB } from '../../core/engine/db/connectDB.js';

const users = () => getDB().collection('users');

const COLLATION_OPTIONS = { collation: { locale: "en", strength: 2 } };

const USER_PROJECTION = { email: 0, passwordHash: 0 };


// get user
export const getUser = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne(
      { customId: userId },
      { projection: USER_PROJECTION, ...COLLATION_OPTIONS }
    );

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const userResponse = user;

    // Exclude gender if hideGender === true
    if (userResponse.settings.privacy.hideGender) {
      delete userResponse.profile.gender;
    }

    return res.status(200).json(userResponse);
  } catch (error) {
    handleServerError(res, error);
  }
};
// /get user

// get users
export const getUsers = async (req, res) => {
  try {
    const { exclude, limit, q } = req.query;
    const query = exclude ? { customId: { $ne: exclude } } : {};
    const max = parseInt(limit) || 4;

    // Optional search by name or @customId (case-insensitive).
    if (q && q.trim()) {
      const safe = q.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const rx = new RegExp(safe, 'i');
      query.$or = [{ name: rx }, { customId: rx }];
    }

    const foundUsers = await users().find(query, { projection: USER_PROJECTION })
      .limit(max)
      .sort({ createdAt: -1 })
      .toArray();

    const usersResponse = foundUsers.map(user => {
      // 'user' is already a clean object
      if (user.settings.privacy.hideGender) {
        delete user.profile.gender;
      }
      return user;
    });

    res.status(200).json(usersResponse);
  } catch (error) {
    handleServerError(res, error);
  }
};
// /get users

// get user, for user edit page
export const getUserForUserEditPage = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne(
      { customId: userId },
      { projection: USER_PROJECTION, ...COLLATION_OPTIONS }
    );

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }
    // 'user' is already a clean object
    return res.status(200).json(user);
  } catch (error) {
    handleServerError(res, error);
  }
};

// update user
export const updateUser = async (req, res) => {
  try {
    const userId = req.params.userId;
    const { customId, name, bio, gender, avatarUri, bannerUri } = req.body;

    console.log('req.body = ' + JSON.stringify(req.body))

    // Checking customId
    const newCustomId = customId || 'empty';
    const validation = /^[a-zA-Z0-9-_]{1,35}$/;
    const validationCustomId = validation.test(newCustomId);

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);
    const searchIdenticalUserCustomId = await users().findOne({ customId: newCustomId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: 'User not found' });
    }

    // 'customId' Validation Logic
    const isSameIdCaseInsensitive = userId.toUpperCase() === newCustomId.toUpperCase();
    const isNewIdTaken = searchIdenticalUserCustomId && searchIdenticalUserCustomId._id.toString() !== user._id.toString();

    if (!isSameIdCaseInsensitive && isNewIdTaken) {
      return res.status(409).json({ message: 'This Id already exists' });
    }
    if (!validationCustomId) {
      return res.status(401).json({ message: 'Minimum length of id is 1 character, maximum 35, Latin letters, numbers, underscores and dashes are allowed' });
    }

    // 'gender' verification
    if (gender !== undefined) {
      if (!gender || typeof gender !== 'object') {
        return res.status(400).json({ message: "gender must be an object" });
      }
      const { type, customValue } = gender;
      if (!['male', 'female', 'unspecified', 'custom'].includes(type)) {
        return res.status(400).json({ message: "Invalid gender type" });
      }

      /* ⚠️ ATTENTION, DANGER ZONE ❗❗❗
       Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
       After deleting or commenting out this code, gender customization will be enabled, related code in - UserEditPage.jsx ⬇️
       */

      if (type === 'custom') {
        return res.status(403).json({ message: "Gender selection feature is not available" });
      }

      /* /⚠️ ATTENTION, DANGER ZONE ❗❗❗⬆️
       Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
       After deleting or commenting out this code, gender customization will be enabled, related code in - UserEditPage.jsx
       */

      if (type === 'custom' && (!customValue || typeof customValue !== 'string' || customValue.length > 50)) {
        return res.status(400).json({ message: "customValue must be a string up to 50 characters" });
      }

      if (type !== 'custom' && customValue !== undefined) {
        return res.status(400).json({ message: "customValue is only allowed for custom gender type" });
      }
    }

    // Get the old avatarUri and bannerUri values
    const oldAvatarUri = req.body.oldAvatarUri || user.avatarUri || '';
    const oldBannerUri = req.body.oldBannerUri || user.bannerUri || '';

    // We are creating updates
    const updates = {
      name: name !== undefined ? name : user.name,
      customId: newCustomId === 'empty' ? user.customId : newCustomId,
      'profile.bio': bio !== undefined ? bio : user.profile.bio,
      avatarUri: avatarUri !== undefined ? avatarUri : oldAvatarUri,
      bannerUri: bannerUri !== undefined ? bannerUri : oldBannerUri,
      updatedAt: new Date(), // Manually updating the timestamp
    };
    if (gender !== undefined) {
      updates['profile.gender.type'] = gender.type;
      updates['profile.gender.customValue'] = gender.customValue || '';
    }

    // Updating the user

    await users().updateOne(
      { _id: user._id }, // Update by _id for reliability
      { $set: updates }
    );

    // Delete the old avatar if it has changed
    if (avatarUri !== undefined && oldAvatarUri && oldAvatarUri !== avatarUri) {
      const avatarPath = path.join(process.cwd(), oldAvatarUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(avatarPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(avatarPath);
          console.log(`Successfully deleted old avatar: ${avatarPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete old avatar ${avatarPath}:`, err);
      }
    }

    // Delete the old banner if it has changed
    if (bannerUri !== undefined && oldBannerUri && oldBannerUri !== bannerUri) {
      const bannerPath = path.join(process.cwd(), oldBannerUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(bannerPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(bannerPath);
          console.log(`Successfully deleted old banner: ${bannerPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete old banner ${bannerPath}:`, err);
      }
    }

    res.status(200).json({ message: 'User changed' });
  } catch (error) {
    handleServerError(res, error);
  }
};
// /update user

// update user settings
export const updateUserSettings = async (req, res) => {
  try {
    const userId = req.params.userId; // customId ("AndrewShedov")
    const { hideGif, hideGender } = req.body;

    // Input data validation
    if (typeof hideGif !== 'boolean' && typeof hideGender !== 'boolean') {
      return res.status(400).json({ message: "hideGif and hideGender must be boolean values" });
    }

    // Generating updates
    const updates = {
      updatedAt: new Date(),
    };
    if (typeof hideGif === 'boolean') {
      updates['settings.interface.hideGif'] = hideGif;
    }
    if (typeof hideGender === 'boolean') {
      updates['settings.privacy.hideGender'] = hideGender;
    }

    // 1. Atomic update using updateOne (doesn't return the document, but is faster)
    // Using updateOne, which is guaranteed to update and return a count
    const result = await users().updateOne(
      { customId: userId },
      { $set: updates },
      {
        ...COLLATION_OPTIONS
      }
    );

    // Verifying that the user was found and modified
    if (result.matchedCount === 0) {
      return res.status(404).json({ message: "User not found" });
    }

    // 2. SUCCESS: Return a success message, just like in Mongoose
    // Now we know for sure that the database has been updated, and the frontend can update itself
    res.status(200).json({ message: "Settings updated", hideGif, hideGender });

  } catch (error) {
    handleServerError(res, error);
  }
};
// /update user settings

// change user password 
export const changePassword = async (req, res) => {
  try {
    const oldPassword = await req.body.oldPassword;
    const newPassword = await req.body.newPassword;
    const newPasswordValidationRule = /^[a-zA-Z\d!@#$%^&*[\]{}()?"\\/,><':;|_~`=+-]{8,35}$/;
    const validationNewPassword = newPasswordValidationRule.test(newPassword);

    if (!validationNewPassword) {
      return res.status(401).json({ message: "The minimum password length is 8 characters, the maximum is 50, Latin letters, numbers and special characters are allowed." });
    }

    const userId = await req.params.userId;

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const bcryptSalt = await bcrypt.genSalt(10);
    const bcryptHash = await bcrypt.hash(newPassword, bcryptSalt);
    const checkOldPassword = await bcrypt.compare(
      oldPassword,
      user.passwordHash
    );

    if (!checkOldPassword) {
      return res.status(401).send({ message: 'Old password is incorrect' });
    }

    await users().updateOne(
      { _id: user._id },
      {
        $set: {
          passwordHash: bcryptHash,
          updatedAt: new Date(), // Manually updating the timestamp
        }
      }
    );

    res.status(200).json({ message: "Password successfully changed" });
  } catch (error) {
    handleServerError(res, error);
  }
};
// /change user password

// delete user account
export const deleteAccount = async (req, res) => {
  try {
    const userId = req.params.userId;

    const user = await users().findOne({ customId: userId }, COLLATION_OPTIONS);

    if (!user) {
      return res.status(404).json({ message: 'User not found' });
    }

    // deleting an avatar if there is one (логика сохранения)
    if (user.avatarUri) {
      const avatarPath = path.join(process.cwd(), user.avatarUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(avatarPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(avatarPath);
          console.log(`Successfully deleted avatar: ${avatarPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete avatar ${avatarPath}:`, err);
      }
    }

    // removing the banner if there is one (saving logic)
    if (user.bannerUri) {
      const bannerPath = path.join(process.cwd(), user.bannerUri.replace('/uploads', 'uploads'));
      try {
        if (await fsPromises.access(bannerPath).then(() => true).catch(() => false)) {
          await fsPromises.unlink(bannerPath);
          console.log(`Successfully deleted banner: ${bannerPath}`);
        }
      } catch (err) {
        console.error(`Failed to delete banner ${bannerPath}:`, err);
      }
    }

    // deleting a user record
    const result = await users().deleteOne({ _id: user._id });

    if (result.deletedCount === 0) {
      return res.status(404).send('User not found for deletion');
    }

    res.status(200).send('User deleted');
  } catch (error) {
    handleServerError(res, error);
  }
};
// /delete user account
