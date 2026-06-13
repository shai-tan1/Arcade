// src/modules/like/like.controller.js

import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const likes = () => getDB().collection('likes');
const users = () => getDB().collection('users');

const COLLATION_OPTIONS = { collation: { locale: 'en', strength: 2 } };

const POST_USER_LOOKUP_PIPELINE_FEED_SIMPLIFIED = [
    {
        $lookup: {
            from: 'users',
            localField: 'user',
            foreignField: '_id',
            as: 'user',
            pipeline: [{
                $project: {
                    _id: 1, name: 1, customId: 1, creator: 1, avatarUri: 1, updatedAt: 1,
                    bio: 1, 'status.isOnline': 1, 'status.lastSeen': 1, 'status.activeConnections': 1,
                }
            }]
        }
    }, {
        $unwind: {
            path: '$user',
            preserveNullAndEmptyArrays: true
        }
    }
];

// Getting a user's liked posts
export const getUserLikedPosts = async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 10;

        const fetchLimit = limit + 1;

        let cursorDate = null;
        if (req.query.cursor) {
            cursorDate = new Date(req.query.cursor);
            if (isNaN(cursorDate.getTime())) {
                return res.status(400).json({ message: 'Invalid cursor date' });
            }
        }

        // 1. Search for a user by customId (First findOne is required)
        const user = await users().findOne({ customId: req.params.userId }, COLLATION_OPTIONS);

        if (!user) {
            return res.status(404).json({ message: 'User not found' });
        }
        const userObjectId = user._id;

        // 2. Forming a request for likes
        const matchQuery = { userId: userObjectId };

        if (cursorDate) {
            matchQuery.postCreatedAt = { $lt: cursorDate };
        }

        // 3. Aggregation for receiving posts
        const pipeline = [
            { $match: matchQuery },
            { $sort: { postCreatedAt: -1 } },
            { $limit: fetchLimit }, // limit + 1
            // Connecting to a collection of posts
            {
                $lookup: {
                    from: 'posts',
                    localField: 'postId',
                    foreignField: '_id',
                    as: 'post',
                }
            },
            { $unwind: "$post" },

            // Save postCreatedAt from the like in the nested post object
            {
                $addFields: {
                    "post.postCreatedAtCursor": "$postCreatedAt"
                }
            },

            { $replaceRoot: { newRoot: "$post" } }, // postCreatedAtCursor remains at the root

            ...POST_USER_LOOKUP_PIPELINE_FEED_SIMPLIFIED,

            // Adding likesCount
            {
                $lookup: {
                    from: 'likes',
                    localField: '_id',
                    foreignField: 'postId',
                    as: 'likesData',
                    pipeline: [
                        { $count: 'totalLikes' }
                    ]
                }
            },
            {
                $addFields: {
                    likesCount: { $ifNull: [{ $arrayElemAt: ['$likesData.totalLikes', 0] }, 0] },
                    isLikedByMe: true,
                }
            },
            { $project: { likesData: 0 } },
        ];

        const fetchedResult = await likes().aggregate(pipeline).toArray();

        // 4. Defining the next cursor
        let nextCursor = null;
        let result = fetchedResult;

        if (fetchedResult.length === fetchLimit) {

            // We get the cursor date DIRECTLY from the aggregated result
            const lastPost = fetchedResult[limit - 1];
            if (lastPost && lastPost.postCreatedAtCursor) {
                // If postCreatedAtCursor is a Date object, convert
                nextCursor = lastPost.postCreatedAtCursor.toISOString();
            }

            // We trim the result to return only LIMIT posts.
            result = fetchedResult.slice(0, limit);
        }

        // 5. Return the result
        return res.status(200).json({ posts: result, nextCursor });

    } catch (error) {
        handleServerError(res, error, "getUserLikedPosts controller");
    }
};