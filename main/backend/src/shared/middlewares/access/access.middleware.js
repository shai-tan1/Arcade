import {
    handleServerError
} from "../../../shared/helpers/index.js";
import {
    getDB
} from "../../../core/engine/db/connectDB.js";
import {
    ObjectId
} from "mongodb";

const users = () => getDB().collection('users');
const posts = () => getDB().collection('posts');

// Collation options (for case-insensitive search by customId)
const COLLATION_OPTIONS = {
    collation: {
        locale: "en",
        strength: 2
    }
};

// can update user
export const canUpdateUser = async (req, res, next) => {
    const authorizedUserId = req.userId?._id;

    try {
        // 1. Search for a user by customId (case-insensitive)
        const editableUserSearchByCustomId = await users().findOne({
            customId: req.params.userId,
        }, COLLATION_OPTIONS);

        // 2. Search for an authorized user by _id (to check creator rights)
        const checkAuthorizedUser = await users().findOne({
            _id: new ObjectId(authorizedUserId)
        });

        if (!editableUserSearchByCustomId) {
            return res.status(404).json({
                message: "User not found"
            });
        }

        // 3. Checking rights: either it is the user himself or the creator user
        if ((authorizedUserId !== editableUserSearchByCustomId._id.toString()) && (checkAuthorizedUser.creator === false)) {
            return res.status(403).json({
                message: "No access"
            });
        };
        next();
    } catch (error) {
        handleServerError(res, error, "canUpdateUser middleware");
    }
};
// /can update user

// can update post
export const canUpdatePost = async (req, res, next) => {
    try {
        const authorizedUserId = req.userId._id;

        // 1. Search for a post by _id
        const post = await posts().findOne({
            _id: new ObjectId(req.params.postId)
        });

        // 2. Search for an authorized user by _id (to check creator rights)
        const checkAuthorizedUser = await users().findOne({
            _id: new ObjectId(authorizedUserId)
        });

        if (!post) {
            return res.status(404).json({
                message: "Post not found"
            });
        }

        // 3. Checking permissions: the post user (ObjectId) is compared with the authorizedUserId (String)
        if ((post.user.toString() !== authorizedUserId) && (checkAuthorizedUser.creator === false)) {
            return res.status(403).json({
                message: "No access"
            });
        }
        next();
    } catch (error) {
        handleServerError(res, error, "canUpdatePost middleware");
    }
};
// /can update post

// can view liked posts
export const canViewLikedPosts = async (req, res, next) => {
    // 1. Finding the user whose liked posts we want to see (by customId)
    const userId = await users().findOne({
        customId: req.params.userId
    }, COLLATION_OPTIONS);

    if (!userId) {
        return res.status(404).json({
            message: "User is not found",
        });
    }
    const authorizedUserId = req.userId._id;

    try {
        // 2. Verification: Only the user can view their own likes
        if (authorizedUserId !== userId._id.toString()) {
            // There could be additional logic here for friends or public profiles,
            // but for now we'll just prohibit it.
            return res.status(403).json({
                message: "No access to view this user's liked posts"
            });
        }
        next();
    } catch (error) {
        handleServerError(res, error, "canViewLikedPosts middleware");
    }
};
// /can view liked posts