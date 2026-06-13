// post.controller.js
import { promises as fsPromises } from 'fs';
import path from 'path';
import {
    handleServerError,
    takeHashtags,
    validateHashtagsForPost
} from '../../shared/helpers/index.js';
import {
    getDB
} from '../../core/engine/db/connectDB.js';
import {
    ObjectId
} from 'mongodb';

const posts = () => getDB().collection('posts');
const hashtags = () => getDB().collection('hashtags');
const users = () => getDB().collection('users');
const likes = () => getDB().collection('likes');

// Constants for projection/population
const USER_FIELDS_FOR_POPULATE = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    createdAt: 1,
    updatedAt: 1
};

const USER_FIELDS_FOR_FEED = {
    ...USER_FIELDS_FOR_POPULATE,
    bio: 1,
    'status.isOnline': 1,
    'status.lastSeen': 1,
    'status.activeConnections': 1,
};

const getPostLookupPipelineFeed = (authorizedUserId) => {
    // 1. Lookup for the user (post author)
    const pipeline = [{
        $lookup: {
            from: 'users',
            localField: 'user',
            foreignField: '_id',
            as: 'user',
            pipeline: [{
                $project: USER_FIELDS_FOR_FEED
            }]
        }
    }, {
        $unwind: {
            path: '$user',
            preserveNullAndEmptyArrays: true
        }
    }];

    // 2. Lookup for total likes
    pipeline.push({
        $lookup: {
            from: 'likes',
            localField: '_id',
            foreignField: 'postId',
            as: 'likesData', // Temporary name for the lookup result
            pipeline: [
                // We immediately count the number of documents in the sub-pipeline
                { $count: 'totalLikes' }
            ]
        }
    }, {
        $addFields: {
            // Extract the calculated value from the array (it will always be the first element)
            // If the array is empty (no likes), set it to 0
            likesCount: { $ifNull: [{ $arrayElemAt: ['$likesData.totalLikes', 0] }, 0] }
        }
    }, {
        $project: { likesData: 0 } // Clearing the temporary field
    });

    // 3. Lookup to check the like status of the current user (isLikedByMe)
    if (authorizedUserId) {
        pipeline.push(
            {
                $lookup: {
                    from: 'likes',
                    let: { postId: '$_id' },
                    pipeline: [
                        {
                            $match: {
                                $expr: {
                                    $and: [
                                        { $eq: ['$postId', '$$postId'] },
                                        { $eq: ['$userId', authorizedUserId] }
                                    ]
                                }
                            }
                        },
                        { $limit: 1 }
                    ],
                    as: 'likeStatus'
                }
            },
            {
                $addFields: {
                    // isLikedByMe = true, if likeStatus size > 0
                    isLikedByMe: { $gt: [{ $size: "$likeStatus" }, 0] }
                }
            },
            { $project: { likeStatus: 0 } } // Clearing the temporary field
        );
    } else {
        // If the user is not logged in, isLikedByMe = false
        pipeline.push({ $addFields: { isLikedByMe: false } });
    }

    return pipeline;
};

// create post
export const createPost = async (req, res) => {
    try {
        const combiningTitleAndText = (req.body?.title + ' ' + req.body.text)
            .split(/[\s\n\r]/gmi)
            .filter(v => v.startsWith('#'));

        // We receive only valid, clean and unique tags (without #)
        const newHashtags = takeHashtags(combiningTitleAndText);

        // Centralized check for quantity and length hashtags
        const validationResult = validateHashtagsForPost(newHashtags);
        if (!validationResult.valid) {
            return res.status(400).json({
                message: validationResult.message
            });
        }

        const newPost = {
            _id: new ObjectId(),
            title: req.body?.title || '',
            text: req.body.text || '',
            mainImageUri: req.body.mainImageUri,
            user: new ObjectId(req.userId._id),
            views: 0,
            createdAt: new Date(),
            updatedAt: new Date(),
        };

        if (!(newPost.mainImageUri || (newPost.text.length >= 1))) {
            return res.status(400).json({
                message: 'Post should not be empty'
            });
        }

        // 1. Saving a post
        await posts().insertOne(newPost);
        const post = newPost;

        // 2. Hashtag logic
        const postId = post._id;
        const postCreatedAt = post.createdAt;

        if (newHashtags.length > 0) {
            const hashtagDocs = newHashtags.map((tag) => ({
                name: tag, // Only valid tags here
                postId,
                postCreatedAt,
                createdAt: new Date(),
                updatedAt: new Date(),
            }));

            await hashtags().bulkWrite(
                hashtagDocs.map((doc) => ({
                    insertOne: {
                        document: doc
                    }
                })), {
                ordered: false
            }
            );
        }
        // /Hashtag logic

        res.status(200).json(post);
    } catch (error) {
        handleServerError(res, error);
    }
};

// update post
export const updatePost = async (req, res) => {
    try {
        const postId = req.params.postId;
        const postIdObject = new ObjectId(postId);

        const post = await posts().findOne({
            _id: postIdObject
        });

        const postImage = req.body.mainImageUri;
        const postText = req.body.text;

        const combiningTitleAndText = (req.body?.title + ' ' + req.body.text)
            .split(/[\s\n\r]/gmi)
            .filter(v => v.startsWith('#'));

        // We receive only valid, clean and unique tags (without #)
        const newHashtags = takeHashtags(combiningTitleAndText);

        // Centralized check for quantity and length
        const validationResult = validateHashtagsForPost(newHashtags);
        if (!validationResult.valid) {
            return res.status(400).json({
                message: validationResult.message
            });
        }

        if (!(postImage || (postText.length >= 1))) {
            return res.status(400).json({
                message: 'Post should not be empty'
            });
        }
        if (!post) {
            return res.status(404).json({
                message: 'Post not found'
            });
        }

        if (postImage !== undefined && post.mainImageUri && post.mainImageUri !== postImage) {
            const oldImagePath = path.join(process.cwd(), post.mainImageUri.replace('/uploads', 'uploads'));
            try {
                if (await fsPromises.access(oldImagePath).then(() => true).catch(() => false)) {
                    await fsPromises.unlink(oldImagePath);
                    console.log(`Successfully deleted old image: ${oldImagePath}`);
                }
            } catch (err) {
                console.error(`Failed to delete old image ${oldImagePath}:`, err);
            }
        }

        const newMainImageUri = postImage !== undefined ? postImage : (post.mainImageUri || "");

        const updateDoc = {
            $set: {
                title: req.body.title || '',
                text: req.body.text || '',
                mainImageUri: newMainImageUri,
                updatedAt: new Date(),
            }
        };

        await posts().updateOne({
            _id: postIdObject
        }, updateDoc);

        const postCreatedAt = post.createdAt;

        // 3. Hashtag logic: Delete old and insert new
        await hashtags().deleteMany({
            postId: postIdObject
        });

        if (newHashtags.length > 0) {
            const hashtagDocs = newHashtags.map((tag) => ({
                name: tag, // Only valid tags here
                postId: postIdObject,
                postCreatedAt: postCreatedAt,
                createdAt: new Date(),
                updatedAt: new Date(),
            }));

            await hashtags().bulkWrite(
                hashtagDocs.map((doc) => ({
                    insertOne: {
                        document: doc
                    }
                })), {
                ordered: false
            }
            );
        }
        // /Hashtag logic

        res.status(200).json({
            postId: req.params.postId,
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

// get post

export const getPost = async (req, res) => {
    try {
        const postId = req.params.postId;
        const postIdObject = new ObjectId(postId);

        let authorizedUserId = req.query.authorizedUserId;

        if (authorizedUserId) {
            authorizedUserId = new ObjectId(authorizedUserId);
        } else {
            authorizedUserId = undefined;
        }

        // 1. Aggregation to obtain a post with full information
        const pipeline = [
            { $match: { _id: postIdObject } },
            // pass the authorizedUserId to enable like verification
            ...getPostLookupPipelineFeed(authorizedUserId),
            { $limit: 1 }
        ];

        const [post] = await posts().aggregate(pipeline).toArray();

        if (!post) {
            return res.status(404).json({ message: 'Post not found' });
        }

        // 2. Bringing back the enriched post
        res.status(200).json(post);
    } catch (error) {
        handleServerError(res, error, "getPost controller");
    }
};

// add view
export const addView = async (req, res) => {
    try {
        const postId = req.params.postId;

        // 1. Check that the post ID exists
        if (!postId) {
            return res.status(400).json({ message: "Post ID is required" });
        }

        // 2. Convert ID to ObjectId
        const postIdObject = new ObjectId(postId);

        // 3. Atomic View Counter Increment (VIEWS)
        // This request is executed quickly and only once when the frontend calls it.
        await posts().updateOne(
            { _id: postIdObject },
            { $inc: { views: 1 } }
        );

        // 4. Return 204 No Content (Success, but no response body)
        return res.status(204).end();

    } catch (error) {
        if (error.name === 'BSONTypeError' || error.message.includes('ObjectId')) {
            return res.status(400).json({ message: "Invalid Post ID format" });
        }
        handleServerError(res, error, "addView controller");
    }
};

// get post, for post edit page 
export const getPostForPostEditPage = async (req, res) => {
    try {
        const postId = req.params.postId;
        const postIdObject = new ObjectId(postId);

        // 1. We find the post
        const post = await posts().findOne({ _id: postIdObject });

        if (!post) {
            return res.status(404).json({
                message: "Post not found"
            });
        }

        // 2. Manual user "population"
        const user = await users().findOne(
            { _id: post.user },
            { projection: USER_FIELDS_FOR_POPULATE }
        );

        // 3. We do not return 404 if the author is deleted.
        if (!user) {
            post.user = null;
        } else {
            post.user = user;
        }

        return res.status(200).json(post);
    } catch (error) {
        handleServerError(res, error);
    }
};
// /get post, for post edit page

// get posts
export const getPosts = async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 10;
        const page = parseInt(req.query.page) || 1;
        const skip = (page - 1) * limit;

        // Get the user ID from the query parameter (if passed)
        let authorizedUserId = req.query.authorizedUserId;

        // Convert ID to ObjectId if it exists.
        // If the user is not authorized, authorizedUserId will remain undefined.
        if (authorizedUserId) {
            authorizedUserId = new ObjectId(authorizedUserId);
        } else {
            authorizedUserId = undefined;
        }

        const totalPosts = await posts().countDocuments({});
        const totalPages = Math.ceil(totalPosts / limit);

        const pipeline = [
            { $sort: { createdAt: -1 } },
            { $skip: skip },
            { $limit: limit },
            // pass the authorizedUserId to enable like verification
            ...getPostLookupPipelineFeed(authorizedUserId)
        ];

        const result = await posts().aggregate(pipeline).toArray();

        res.set('X-Total-Count', totalPosts);
        return res.status(200).json({
            posts: result,
            currentPage: page,
            totalPages,
            totalPosts,
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

// get posts by user
export const getPostsByUser = async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 10;
        const page = parseInt(req.query.page) || 1;
        const skip = (page - 1) * limit;

        // get the ID of the authorized user from the Query Parameter
        let authorizedUserId = req.query.authorizedUserId;

        // Convert it to ObjectId if it exists
        if (authorizedUserId) {
            authorizedUserId = new ObjectId(authorizedUserId);
        } else {
            authorizedUserId = undefined;
        }

        const COLLATION_OPTIONS = { collation: { locale: 'en', strength: 2 } };
        const user = await users().findOne({ customId: req.params.userId }, COLLATION_OPTIONS);

        if (!user) {
            return res.status(404).json({ message: 'User not found' });
        }

        const userObjectId = user._id;

        const matchQuery = { user: userObjectId };
        const totalPosts = await posts().countDocuments(matchQuery);
        const totalPages = Math.ceil(totalPosts / limit);

        const pipeline = [
            { $match: matchQuery },
            { $sort: { createdAt: -1 } },
            { $skip: skip },
            { $limit: limit },
            // pass the authorizedUserId to enable like verification
            ...getPostLookupPipelineFeed(authorizedUserId)
        ];

        const result = await posts().aggregate(pipeline).toArray();

        res.set('X-Total-Count', totalPosts);
        return res.status(200).json({
            posts: result,
            currentPage: page,
            totalPages,
            totalPosts,
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

// get posts by hashtag
export const getPostsByHashtag = async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 10;
        // The tag comes from the URL (useParams), we search for it in the database in lowercase
        const hashtag = req.query.tag.toLowerCase();

        let authorizedUserId = req.query.authorizedUserId;
        if (authorizedUserId) {
            authorizedUserId = new ObjectId(authorizedUserId);
        } else {
            authorizedUserId = undefined;
        }

        // Pagination logic
        let hashtagQuery = { name: hashtag };
        if (req.query.cursor) {
            const cursorDate = new Date(req.query.cursor);
            if (isNaN(cursorDate.getTime())) {
                return res.status(400).json({ message: 'Invalid cursor date' });
            }
            hashtagQuery.postCreatedAt = { $lt: cursorDate };
        }

        const hashtagDocs = await hashtags().find(hashtagQuery)
            .sort({ postCreatedAt: -1 })
            .limit(limit)
            .project({ postId: 1, postCreatedAt: 1 })
            .toArray();

        const postIds = hashtagDocs.map(doc => doc.postId);

        if (postIds.length === 0) {
            return res.status(200).json({ posts: [], nextCursor: null });
        }

        const idToIndexMap = new Map();
        postIds.forEach((id, index) => idToIndexMap.set(id.toString(), index));
        // /Pagination logic

        const fetchedPosts = await posts().aggregate([
            { $match: { _id: { $in: postIds } } },
            // pass the authorizedUserId to enable like verification
            ...getPostLookupPipelineFeed(authorizedUserId)
        ]).toArray();

        const resultPosts = fetchedPosts.sort((a, b) => {
            const indexA = idToIndexMap.get(a._id.toString());
            const indexB = idToIndexMap.get(b._id.toString());
            return indexA - indexB;
        });

        // check that the array is not empty before taking an element.
        let nextCursor = null;
        if (hashtagDocs.length > 0) {
            nextCursor = hashtagDocs[hashtagDocs.length - 1].postCreatedAt.toISOString();
        }

        return res.status(200).json({ posts: resultPosts, nextCursor });
    } catch (error) {
        handleServerError(res, error);
    }
};

// delete post
export const deletePost = async (req, res) => {
    try {
        const postId = req.params.postId;
        const postIdObject = new ObjectId(postId);

        const post = await posts().findOne({ _id: postIdObject });

        if (!post) {
            return res.status(404).json({ message: 'Post not found' });
        }

        await posts().deleteOne({ _id: postIdObject });

        await hashtags().deleteMany({ postId: postIdObject });

        if (post.mainImageUri) {
            const mainImagePath = path.join(process.cwd(), post.mainImageUri.replace('/uploads', 'uploads'));
            try {
                if (await fsPromises.access(mainImagePath).then(() => true).catch(() => false)) {
                    await fsPromises.unlink(mainImagePath);
                    console.log(`Successfully deleted main image: ${mainImagePath}`);
                }
            } catch (err) {
                console.error(`Failed to delete main image ${mainImagePath}:`, err);
            }
        }

        res.status(200).json({ message: 'Post deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

// delete all posts by user
export const deleteAllPostsByUser = async (req, res) => {
    try {
        const COLLATION_OPTIONS = { collation: { locale: 'en', strength: 2 } };
        const user = await users().findOne({ customId: req.params.userId }, COLLATION_OPTIONS);

        if (!user) {
            return res.status(404).json({ message: 'User not found' });
        }

        const postsToDelete = await posts().find({ user: user._id })
            .project({ _id: 1, mainImageUri: 1 })
            .toArray();

        if (!postsToDelete || postsToDelete.length === 0) {
            return res.status(404).json({ message: 'Posts not found' });
        }

        const postIdsToDelete = postsToDelete.map(post => post._id);

        for (const post of postsToDelete) {
            if (post.mainImageUri) {
                const mainImagePath = path.join(process.cwd(), post.mainImageUri.replace('/uploads', 'uploads'));
                try {
                    if (await fsPromises.access(mainImagePath).then(() => true).catch(() => false)) {
                        await fsPromises.unlink(mainImagePath);
                        console.log(`Successfully deleted main image: ${mainImagePath}`);
                    }
                } catch (err) {
                    console.error(`Failed to delete main image ${mainImagePath}:`, err);
                }
            }
        }

        await hashtags().deleteMany({ postId: { $in: postIdsToDelete } });

        await posts().deleteMany({ user: user._id });

        res.status(200).json({ message: 'All posts deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const likePost = async (req, res) => {
    try {
        const postId = req.params.postId;
        const authorizedUserId = req.userId._id; // Obtained from middleware auth

        if (!postId) {
            return res.status(400).json({ message: "Post ID is required" });
        }

        const postIdObject = new ObjectId(postId);
        const userIdObject = new ObjectId(authorizedUserId);

        // 1. We check if a post exists and get its creation date.
        const post = await posts().findOne(
            { _id: postIdObject },
            { projection: { createdAt: 1 } }
        );

        if (!post) {
            return res.status(404).json({ message: 'Post not found' });
        }

        const likeDocument = {
            userId: userIdObject,
            postId: postIdObject,
        };

        // 2. Attempt to delete a like
        const deleteResult = await likes().deleteOne(likeDocument);

        if (deleteResult.deletedCount > 0) {
            // Like removed (Dislike)
            return res.status(200).json({ message: 'Post disliked', liked: false });
        }

        // 3. If the like isn't deleted, it needs to be added.
        const newLike = {
            ...likeDocument,
            postCreatedAt: post.createdAt, // Denormalization
            createdAt: new Date(),
            updatedAt: new Date(),
        };

        // Attempt to add a like
        await likes().insertOne(newLike);

        // Like added
        return res.status(200).json({ message: 'Post liked', liked: true });

    } catch (error) {
        // The unique index `user_post_unique_idx` can cause error 11000,
        // but we're already handling it via `deleteOne`/`insertOne`, so
        // we're just catching common errors here.
        handleServerError(res, error, "likePost controller");
    }
};

export const searchPosts = async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 5;
        const searchQuery = req.query.q;

        if (!searchQuery || searchQuery.trim() === '') {
            return res.status(200).json({ posts: [], nextCursor: null });
        }

        let authorizedUserId = req.query.authorizedUserId;
        if (authorizedUserId) {
            authorizedUserId = new ObjectId(authorizedUserId);
        } else {
            authorizedUserId = undefined;
        }

        const trimmedQuery = searchQuery.trim();

        // 1. Search criteria: use ONLY $text
        const searchMatchCriteria = { $text: { $search: trimmedQuery } };

        // 2. Defining the cursor
        const cursorMatch = {};
        if (req.query.cursor) {
            const cursorDate = new Date(req.query.cursor);
            if (isNaN(cursorDate.getTime())) {
                return res.status(400).json({ message: 'Invalid cursor date' });
            }
            // Cursor: Find posts created BEFORE the last post date
            cursorMatch.createdAt = { $lt: cursorDate };
        }

        // 3. Final $match
        const finalMatchCriteria = { ...searchMatchCriteria, ...cursorMatch };
        const matchStage = { $match: finalMatchCriteria };

        // 4. Main pipeline
        const pipeline = [
            matchStage,
            // select sorting by date for STABILITY of CURSOR pagination.
            // Posts will be sorted by date
            { $sort: { createdAt: -1 } },
            { $limit: limit },

            // pass the authorizedUserId to enable like verification
            ...getPostLookupPipelineFeed(authorizedUserId)
        ];

        const result = await posts().aggregate(pipeline).toArray();

        // 5. Calculating the next cursor
        let nextCursor = null;
        if (result.length === limit) {
            // The cursor is the creation date of the last post.
            nextCursor = result[result.length - 1].createdAt.toISOString();
        }

        // 6. return only posts and nextCursor
        return res.status(200).json({
            posts: result,
            nextCursor
        });

    } catch (error) {
        handleServerError(res, error);
    }
};