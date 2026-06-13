import express from "express";
import { auth } from "../auth/index.js";
import * as controller from "./user.controller.js";
import {
  canUpdateUser
} from "../../shared/middlewares/index.js";
import { sharp } from "../../shared/utils/index.js";
const router = express.Router();

// get users
router.get("/",
  controller.getUsers
);
// /get users

// get user
router.get("/:userId",
  controller.getUser
);
// /get user

// get user, for user edit page
router.get("/:userId/edit",
  auth,
  // updateLastSeenMiddleware, 
  canUpdateUser,
  controller.getUserForUserEditPage);
// /get user, for user edit page

// upload user image
router.post("/:userId/image",
  auth,
  // updateLastSeenMiddleware,
  canUpdateUser,
  sharp.processImage,
  sharp.errors,
  async (req, res) => {
    try {
      if (!req.processedFile) {
        return res.status(400).json({ error: "No processed file available." });
      }

      res.json({
        imageUri: req.processedFile.url || `/uploads/users/images/${req.processedFile.filename}`,
        userId: req.params.userId,
      });
    } catch (err) {
      res.status(500).json({ error: "Failed to process file." });
    }
  });
// /upload user image

// update user profile
router.patch(
  "/:userId",
  auth,
  // updateLastSeenMiddleware,
  canUpdateUser,
  controller.updateUser
);
// /update user profile

// update user settings
router.patch(
  "/:userId/settings",
  auth,
  // updateLastSeenMiddleware,
  canUpdateUser,
  controller.updateUserSettings
);
// /update user settings

// change user password
router.post(
  "/:userId/password",
  auth,
  // updateLastSeenMiddleware,
  canUpdateUser,
  controller.changePassword
);
// /change user password

// delete user account
router.delete("/:userId",
  auth,
  // updateLastSeenMiddleware,
  canUpdateUser,
  controller.deleteAccount);
// /delete user account

export default router;
