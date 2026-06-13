import express from 'express';
import * as controller from './post.controller.js';
import { auth } from '../auth/index.js';
import { canUpdatePost, canUpdateUser } from '../../shared/middlewares/index.js';
import { validation } from '../../shared/validation/index.js';
import { sharp } from '../../shared/utils/index.js';

const router = express.Router();

// create post
router.post('/', auth, validation.createPost, validation.errors, controller.createPost);

// add a post image
router.post('/:postId/image', auth, canUpdatePost, sharp.processImage, sharp.errors, async (req, res) => {
  try {
    if (!req.processedFile) {
      return res.status(400).json({ error: 'No processed file available.' });
    }
    res.json({
      imageUri: req.processedFile.url || `/uploads/posts/images/${req.processedFile.filename}`,
      postId: req.params.postId,
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to process file.' });
  }
});

// update post
router.patch('/:postId', auth, canUpdatePost, validation.createPost, validation.errors, controller.updatePost);

// get posts by hashtag
router.get('/hashtags', controller.getPostsByHashtag);

// 💡 NEW: Search posts
router.get('/search', controller.searchPosts);

// get post
router.get('/:postId', controller.getPost);

// get post, for post edit page
router.get('/:postId/edit', auth, canUpdatePost, controller.getPostForPostEditPage);

// get posts by user
router.get('/user/:userId', controller.getPostsByUser);

// get posts
router.get('/', controller.getPosts);

// delete post
router.delete('/:postId', auth, canUpdatePost, controller.deletePost);

// delete all posts by user
router.delete('/user/:userId', auth, canUpdateUser, controller.deleteAllPostsByUser);

// add like
router.patch("/:postId/like", 
  auth, 
  controller.likePost
);

// add view
router.post("/:postId/view", controller.addView);

export default router;