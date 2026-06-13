#!/usr/bin/env bash
# Forums feature (Codeforces-blog style): topics + threaded comments + voting.
# Adds a backend module (forumTopics / forumComments collections, routes, controller)
# and a frontend ForumsPage, plus a sidebar entry, routes, and locales.
# Idempotent and safe to re-run. Run from your repo's main/ directory.
set -e
if [ ! -d frontend/src ] || [ ! -d backend/src ]; then echo "ERROR: run from your repo's main/ directory"; exit 1; fi

mkdir -p backend/src/modules/forum
mkdir -p frontend/src/pages/ForumsPage

cat > backend/src/modules/forum/forum.schema.js << 'XEOF'
// src/modules/forum/forum.schema.js

export const FORUM_TOPIC_SCHEMA = {
    bsonType: 'object',
    required: ['authorId', 'title', 'body', 'createdAt'],
    properties: {
        authorId: { bsonType: 'objectId' },
        title: { bsonType: 'string' },
        body: { bsonType: 'string' },
        tags: { bsonType: 'array', items: { bsonType: 'string' } },
        commentCount: { bsonType: ['int', 'long'] },
        upvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        downvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        createdAt: { bsonType: 'date' },
        updatedAt: { bsonType: 'date' }
    }
};

export const FORUM_TOPIC_INDEXES = [
    { key: { createdAt: -1 } },
    { key: { authorId: 1 } }
];

export const FORUM_COMMENT_SCHEMA = {
    bsonType: 'object',
    required: ['topicId', 'authorId', 'body', 'createdAt'],
    properties: {
        topicId: { bsonType: 'objectId' },
        authorId: { bsonType: 'objectId' },
        parentId: { bsonType: ['objectId', 'null'] },
        body: { bsonType: 'string' },
        deleted: { bsonType: 'bool' },
        upvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        downvoters: { bsonType: 'array', items: { bsonType: 'objectId' } },
        createdAt: { bsonType: 'date' },
        updatedAt: { bsonType: 'date' }
    }
};

export const FORUM_COMMENT_INDEXES = [
    { key: { topicId: 1, createdAt: 1 } },
    { key: { parentId: 1 } }
];
XEOF
echo "  + backend/src/modules/forum/forum.schema.js"

cat > backend/src/modules/forum/forum.controller.js << 'XEOF'
// src/modules/forum/forum.controller.js

import { ObjectId } from 'mongodb';
import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const topics = () => getDB().collection('forumTopics');
const comments = () => getDB().collection('forumComments');

const USER_PUBLIC_PROJECTION = {
    _id: 1,
    name: 1,
    customId: 1,
    creator: 1,
    avatarUri: 1,
    'status.isOnline': 1
};

const LIMITS = { title: 200, body: 20000, comment: 10000, tag: 30, tags: 6, page: 30 };

/* ---------------- helpers ---------------- */

function cleanString(v, max) {
    if (typeof v !== 'string') return '';
    return v.trim().slice(0, max);
}

function cleanTags(v) {
    if (!Array.isArray(v)) return [];
    const out = [];
    for (const raw of v) {
        if (typeof raw !== 'string') continue;
        const tag = raw.trim().toLowerCase().slice(0, LIMITS.tag);
        if (tag && !out.includes(tag)) out.push(tag);
        if (out.length >= LIMITS.tags) break;
    }
    return out;
}

// score + my vote computed from voter arrays, added to an aggregation pipeline.
function voteFields(myId) {
    return {
        score: {
            $subtract: [
                { $size: { $ifNull: ['$upvoters', []] } },
                { $size: { $ifNull: ['$downvoters', []] } }
            ]
        },
        myVote: {
            $cond: [
                { $in: [myId, { $ifNull: ['$upvoters', []] }] },
                1,
                { $cond: [{ $in: [myId, { $ifNull: ['$downvoters', []] }] }, -1, 0] }
            ]
        }
    };
}

const authorLookup = {
    $lookup: {
        from: 'users',
        localField: 'authorId',
        foreignField: '_id',
        as: 'author',
        pipeline: [{ $project: USER_PUBLIC_PROJECTION }]
    }
};

async function applyVote(collection, docId, myId, dir) {
    await collection.updateOne({ _id: docId }, { $pull: { upvoters: myId, downvoters: myId } });
    if (dir === 1) await collection.updateOne({ _id: docId }, { $addToSet: { upvoters: myId } });
    else if (dir === -1) await collection.updateOne({ _id: docId }, { $addToSet: { downvoters: myId } });
    const doc = await collection.findOne({ _id: docId }, { projection: { upvoters: 1, downvoters: 1 } });
    const up = doc?.upvoters || [];
    const down = doc?.downvoters || [];
    return {
        score: up.length - down.length,
        myVote: up.some((u) => u.equals(myId)) ? 1 : down.some((u) => u.equals(myId)) ? -1 : 0
    };
}

/* ---------------- topics ---------------- */

export const listTopics = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const page = Math.max(0, parseInt(req.query.page, 10) || 0);
        const list = await topics().aggregate([
            { $sort: { createdAt: -1 } },
            { $skip: page * LIMITS.page },
            { $limit: LIMITS.page },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    title: 1,
                    tags: 1,
                    author: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    commentCount: { $ifNull: ['$commentCount', 0] },
                    snippet: { $substrCP: ['$body', 0, 220] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const createTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const title = cleanString(req.body?.title, LIMITS.title);
        const body = cleanString(req.body?.body, LIMITS.body);
        const tags = cleanTags(req.body?.tags);
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        const now = new Date();
        const doc = {
            authorId: myId,
            title,
            body,
            tags,
            commentCount: 0,
            upvoters: [],
            downvoters: [],
            createdAt: now,
            updatedAt: now
        };
        const result = await topics().insertOne(doc);
        res.status(201).json({ topicId: result.insertedId });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const getTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const [topic] = await topics().aggregate([
            { $match: { _id: new ObjectId(id) } },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    title: 1,
                    body: 1,
                    tags: 1,
                    author: 1,
                    authorId: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    commentCount: { $ifNull: ['$commentCount', 0] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        topic.isOwner = topic.authorId.equals(myId);
        delete topic.authorId;
        res.status(200).json(topic);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const updateTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const topic = await topics().findOne({ _id: new ObjectId(id) });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        if (!topic.authorId.equals(myId)) return res.status(403).json({ message: 'Not allowed' });

        const title = cleanString(req.body?.title, LIMITS.title);
        const body = cleanString(req.body?.body, LIMITS.body);
        const tags = cleanTags(req.body?.tags);
        if (!title) return res.status(400).json({ message: 'A title is required' });
        if (!body) return res.status(400).json({ message: 'A body is required' });

        await topics().updateOne(
            { _id: topic._id },
            { $set: { title, body, tags, updatedAt: new Date() } }
        );
        res.status(200).json({ topicId: topic._id });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const deleteTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const topic = await topics().findOne({ _id: new ObjectId(id) });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        const isCreator = req.userId.creator === true;
        if (!topic.authorId.equals(myId) && !isCreator) return res.status(403).json({ message: 'Not allowed' });

        await comments().deleteMany({ topicId: topic._id });
        await topics().deleteOne({ _id: topic._id });
        res.status(200).json({ status: 'deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const voteTopic = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const dir = [1, -1, 0].includes(req.body?.dir) ? req.body.dir : 0;
        const topic = await topics().findOne({ _id: new ObjectId(id) }, { projection: { _id: 1 } });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });
        const result = await applyVote(topics(), topic._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};

/* ---------------- comments ---------------- */

export const listComments = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const list = await comments().aggregate([
            { $match: { topicId: new ObjectId(id) } },
            { $sort: { createdAt: 1 } },
            authorLookup,
            { $unwind: '$author' },
            {
                $project: {
                    parentId: 1,
                    author: 1,
                    createdAt: 1,
                    updatedAt: 1,
                    deleted: { $ifNull: ['$deleted', false] },
                    body: { $cond: [{ $eq: ['$deleted', true] }, '', '$body'] },
                    ...voteFields(myId)
                }
            }
        ]).toArray();
        res.status(200).json(list);
    } catch (error) {
        handleServerError(res, error);
    }
};

export const createComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { id } = req.params;
        if (!ObjectId.isValid(id)) return res.status(400).json({ message: 'Invalid topic id' });
        const body = cleanString(req.body?.body, LIMITS.comment);
        if (!body) return res.status(400).json({ message: 'A comment cannot be empty' });

        const topic = await topics().findOne({ _id: new ObjectId(id) }, { projection: { _id: 1 } });
        if (!topic) return res.status(404).json({ message: 'Topic not found' });

        let parentId = null;
        if (req.body?.parentId) {
            if (!ObjectId.isValid(req.body.parentId)) return res.status(400).json({ message: 'Invalid parent id' });
            const parent = await comments().findOne({ _id: new ObjectId(req.body.parentId) });
            if (!parent || !parent.topicId.equals(topic._id)) return res.status(400).json({ message: 'Invalid parent comment' });
            parentId = parent._id;
        }

        const now = new Date();
        const doc = {
            topicId: topic._id,
            authorId: myId,
            parentId,
            body,
            deleted: false,
            upvoters: [],
            downvoters: [],
            createdAt: now,
            updatedAt: now
        };
        const result = await comments().insertOne(doc);
        await topics().updateOne({ _id: topic._id }, { $inc: { commentCount: 1 } });

        const author = await getDB().collection('users').findOne({ _id: myId }, { projection: USER_PUBLIC_PROJECTION });
        res.status(201).json({
            _id: result.insertedId,
            parentId,
            author,
            body,
            deleted: false,
            score: 0,
            myVote: 0,
            createdAt: now,
            updatedAt: now
        });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const updateComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const comment = await comments().findOne({ _id: new ObjectId(commentId) });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        if (comment.deleted) return res.status(400).json({ message: 'Comment was deleted' });
        if (!comment.authorId.equals(myId)) return res.status(403).json({ message: 'Not allowed' });

        const body = cleanString(req.body?.body, LIMITS.comment);
        if (!body) return res.status(400).json({ message: 'A comment cannot be empty' });

        await comments().updateOne({ _id: comment._id }, { $set: { body, updatedAt: new Date() } });
        res.status(200).json({ status: 'updated' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const deleteComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const comment = await comments().findOne({ _id: new ObjectId(commentId) });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        const isCreator = req.userId.creator === true;
        if (!comment.authorId.equals(myId) && !isCreator) return res.status(403).json({ message: 'Not allowed' });
        if (comment.deleted) return res.status(200).json({ status: 'deleted' });

        // Soft delete keeps the thread structure intact for any replies.
        await comments().updateOne({ _id: comment._id }, { $set: { deleted: true, body: '', updatedAt: new Date() } });
        await topics().updateOne({ _id: comment.topicId }, { $inc: { commentCount: -1 } });
        res.status(200).json({ status: 'deleted' });
    } catch (error) {
        handleServerError(res, error);
    }
};

export const voteComment = async (req, res) => {
    try {
        const myId = new ObjectId(req.userId._id);
        const { commentId } = req.params;
        if (!ObjectId.isValid(commentId)) return res.status(400).json({ message: 'Invalid comment id' });
        const dir = [1, -1, 0].includes(req.body?.dir) ? req.body.dir : 0;
        const comment = await comments().findOne({ _id: new ObjectId(commentId) }, { projection: { _id: 1, deleted: 1 } });
        if (!comment) return res.status(404).json({ message: 'Comment not found' });
        if (comment.deleted) return res.status(400).json({ message: 'Comment was deleted' });
        const result = await applyVote(comments(), comment._id, myId, dir);
        res.status(200).json(result);
    } catch (error) {
        handleServerError(res, error);
    }
};
XEOF
echo "  + backend/src/modules/forum/forum.controller.js"

cat > backend/src/modules/forum/forums.routes.js << 'XEOF'
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
XEOF
echo "  + backend/src/modules/forum/forums.routes.js"

cat > frontend/src/pages/ForumsPage/ForumsPage.jsx << 'XEOF'
// frontend/src/pages/ForumsPage/ForumsPage.jsx

import { useState, useEffect } from 'react';
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon } from '../../shared/ui';

import styles from './ForumsPage.module.css';

/* ----------------------------- helpers ----------------------------- */
function timeAgo(d) {
  const s = Math.floor((Date.now() - new Date(d).getTime()) / 1000);
  if (s < 60) return `${Math.max(s, 0)}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const days = Math.floor(h / 24);
  if (days < 30) return `${days}d`;
  const mo = Math.floor(days / 30);
  if (mo < 12) return `${mo}mo`;
  return `${Math.floor(mo / 12)}y`;
}

function buildTree(list) {
  const byId = {};
  const roots = [];
  list.forEach((c) => { byId[c._id] = { ...c, children: [] }; });
  list.forEach((c) => {
    const node = byId[c._id];
    if (c.parentId && byId[c.parentId]) byId[c.parentId].children.push(node);
    else roots.push(node);
  });
  return roots;
}

function Avatar({ user, size = 22 }) {
  const style = { width: size, height: size };
  if (user?.avatarUri) {
    return <img className={styles.avatar} style={style} src={(/^https?:\/\//.test(user.avatarUri) ? user.avatarUri : API_BASE_URL + user.avatarUri)} alt={user.name} />;
  }
  return <span className={`${styles.avatar} ${styles.avatar_empty}`} style={style}><NoAvatarIcon /></span>;
}

function VoteBox({ score, myVote, onVote }) {
  return (
    <div className={styles.vote}>
      <button className={`${styles.varrow} ${myVote === 1 ? styles.up_on : ''}`} onClick={() => onVote(myVote === 1 ? 0 : 1)} aria-label="upvote">▲</button>
      <span className={`${styles.vscore} ${score > 0 ? styles.vpos : score < 0 ? styles.vneg : ''}`}>{score}</span>
      <button className={`${styles.varrow} ${myVote === -1 ? styles.down_on : ''}`} onClick={() => onVote(myVote === -1 ? 0 : -1)} aria-label="downvote">▼</button>
    </div>
  );
}

/* ----------------------------- list ----------------------------- */
function TopicList() {
  const { t } = useTranslation();
  const q = useQuery({ queryKey: ['forums', 'list'], queryFn: () => httpClient.get('/forums'), retry: false });

  return (
    <div className={styles.wrap}>
      <header className={styles.head}>
        <div>
          <h1 className={styles.h1}>{t('ForumsPage.Title')}</h1>
          <p className={styles.sub}>{t('ForumsPage.Subtitle')}</p>
        </div>
        <Link to="/forums/new" className={styles.btn_primary}>{t('ForumsPage.NewTopic')}</Link>
      </header>

      {q.isPending && <div className={styles.center}><div className={styles.loader}><Loader /></div></div>}
      {q.data?.length === 0 && <p className={styles.empty}>{t('ForumsPage.NoTopics')}</p>}

      <ul className={styles.topics}>
        {q.data?.map((tp) => (
          <li key={tp._id} className={styles.topic}>
            <span className={`${styles.listscore} ${tp.score > 0 ? styles.vpos : tp.score < 0 ? styles.vneg : ''}`}>{tp.score}</span>
            <div className={styles.topic_main}>
              <Link to={`/forums/${tp._id}`} className={styles.topic_title}>{tp.title}</Link>
              <p className={styles.topic_snip}>{tp.snippet}{tp.snippet && tp.snippet.length >= 220 ? '…' : ''}</p>
              <div className={styles.meta}>
                <Avatar user={tp.author} size={22} />
                <Link to={`/${tp.author?.customId}`} className={styles.meta_name}>{tp.author?.name}</Link>
                <span className={styles.dot}>·</span><span>{timeAgo(tp.createdAt)}</span>
                <span className={styles.dot}>·</span><span>{tp.commentCount} {t('ForumsPage.CommentsShort')}</span>
                {tp.tags?.map((tag) => <span key={tag} className={styles.tag}>{tag}</span>)}
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* ----------------------------- editor ----------------------------- */
function TopicEditor({ topicId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const editing = !!topicId;
  const existing = useQuery({
    queryKey: ['forums', 'topic', topicId],
    queryFn: () => httpClient.get(`/forums/topic/${topicId}`),
    enabled: editing,
    retry: false
  });

  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [tags, setTags] = useState('');

  useEffect(() => {
    if (editing && existing.data) {
      setTitle(existing.data.title || '');
      setBody(existing.data.body || '');
      setTags((existing.data.tags || []).join(', '));
    }
  }, [editing, existing.data]);

  const save = useMutation({
    mutationFn: () => {
      const payload = { title, body, tags: tags.split(',').map((s) => s.trim()).filter(Boolean) };
      return editing ? httpClient.patch(`/forums/topic/${topicId}`, payload) : httpClient.post('/forums', payload);
    },
    onSuccess: (data) => {
      qc.invalidateQueries({ queryKey: ['forums'] });
      navigate(`/forums/${data.topicId}`);
    }
  });

  const canSave = title.trim() && body.trim() && !save.isPending;

  return (
    <div className={styles.wrap}>
      <header className={styles.head_simple}>
        <Link to={editing ? `/forums/${topicId}` : '/forums'} className={styles.back}>←</Link>
        <h1 className={styles.h1}>{editing ? t('ForumsPage.EditTopic') : t('ForumsPage.NewTopic')}</h1>
      </header>

      <div className={styles.form}>
        <label className={styles.label}>{t('ForumsPage.TitleField')}</label>
        <input className={styles.input} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} placeholder={t('ForumsPage.TitlePlaceholder')} />

        <label className={styles.label}>{t('ForumsPage.BodyField')}</label>
        <textarea className={styles.textarea} value={body} onChange={(e) => setBody(e.target.value)} rows={12} placeholder={t('ForumsPage.BodyPlaceholder')} />

        <label className={styles.label}>{t('ForumsPage.TagsField')}</label>
        <input className={styles.input} value={tags} onChange={(e) => setTags(e.target.value)} placeholder={t('ForumsPage.TagsPlaceholder')} />

        {save.isError && <p className={styles.error}>{save.error?.message || t('ForumsPage.SaveError')}</p>}

        <div className={styles.form_actions}>
          <button className={styles.btn_primary} disabled={!canSave} onClick={() => save.mutate()}>
            {editing ? t('ForumsPage.Save') : t('ForumsPage.Publish')}
          </button>
          <Link to={editing ? `/forums/${topicId}` : '/forums'} className={styles.btn_muted}>{t('ForumsPage.Cancel')}</Link>
        </div>
      </div>
    </div>
  );
}

/* ----------------------------- comment node ----------------------------- */
function CommentNode({ node, myId, t, ctx }) {
  const [replyText, setReplyText] = useState('');
  const [editText, setEditText] = useState(node.body);
  const isReplying = ctx.replyTo === node._id;
  const isEditing = ctx.editing === node._id;
  const mine = !node.deleted && node.author?._id === myId;

  return (
    <div className={styles.cnode}>
      <div className={styles.comment}>
        {node.deleted
          ? <div className={styles.vote}><span className={styles.vscore}>·</span></div>
          : <VoteBox score={node.score} myVote={node.myVote} onVote={(d) => ctx.onVote(node._id, d)} />}
        <div className={styles.comment_main}>
          {node.deleted ? (
            <p className={styles.deleted}>{t('ForumsPage.DeletedComment')}</p>
          ) : (
            <>
              <div className={styles.meta}>
                <Avatar user={node.author} size={20} />
                <Link to={`/${node.author?.customId}`} className={styles.meta_name}>{node.author?.name}</Link>
                <span className={styles.dot}>·</span><span>{timeAgo(node.createdAt)}</span>
              </div>

              {isEditing ? (
                <div className={styles.box}>
                  <textarea className={styles.textarea} rows={3} value={editText} onChange={(e) => setEditText(e.target.value)} />
                  <div className={styles.form_actions}>
                    <button className={styles.btn_primary} disabled={!editText.trim() || ctx.busy} onClick={() => ctx.onEdit(node._id, editText)}>{t('ForumsPage.Save')}</button>
                    <button className={styles.btn_muted} onClick={() => ctx.setEditing(null)}>{t('ForumsPage.Cancel')}</button>
                  </div>
                </div>
              ) : (
                <p className={styles.comment_body}>{node.body}</p>
              )}

              {!isEditing && (
                <div className={styles.comment_actions}>
                  <button className={styles.link_action} onClick={() => { ctx.setReplyTo(isReplying ? null : node._id); setReplyText(''); }}>{t('ForumsPage.Reply')}</button>
                  {mine && <button className={styles.link_action} onClick={() => { ctx.setEditing(node._id); setEditText(node.body); }}>{t('ForumsPage.Edit')}</button>}
                  {mine && <button className={styles.link_action} onClick={() => { if (window.confirm(t('ForumsPage.ConfirmDeleteComment'))) ctx.onDelete(node._id); }}>{t('ForumsPage.Delete')}</button>}
                </div>
              )}
            </>
          )}

          {isReplying && !node.deleted && (
            <div className={styles.box}>
              <textarea className={styles.textarea} rows={3} value={replyText} onChange={(e) => setReplyText(e.target.value)} placeholder={t('ForumsPage.WriteReply')} />
              <div className={styles.form_actions}>
                <button className={styles.btn_primary} disabled={!replyText.trim() || ctx.busy} onClick={() => ctx.onReply(node._id, replyText)}>{t('ForumsPage.Reply')}</button>
                <button className={styles.btn_muted} onClick={() => ctx.setReplyTo(null)}>{t('ForumsPage.Cancel')}</button>
              </div>
            </div>
          )}
        </div>
      </div>

      {node.children?.length > 0 && (
        <div className={styles.children}>
          {node.children.map((child) => (
            <CommentNode key={child._id} node={child} myId={myId} t={t} ctx={ctx} />
          ))}
        </div>
      )}
    </div>
  );
}

/* ----------------------------- topic view ----------------------------- */
function TopicView({ topicId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { authorizedUser } = useAuthData();
  const myId = authorizedUser?._id;

  const topicQ = useQuery({ queryKey: ['forums', 'topic', topicId], queryFn: () => httpClient.get(`/forums/topic/${topicId}`), retry: false });
  const commentsQ = useQuery({ queryKey: ['forums', 'comments', topicId], queryFn: () => httpClient.get(`/forums/topic/${topicId}/comments`), retry: false });

  const [replyTo, setReplyTo] = useState(null);
  const [editing, setEditing] = useState(null);
  const [topComment, setTopComment] = useState('');

  const refreshComments = () => qc.invalidateQueries({ queryKey: ['forums', 'comments', topicId] });
  const refreshTopic = () => qc.invalidateQueries({ queryKey: ['forums', 'topic', topicId] });

  const voteTopic = useMutation({ mutationFn: (dir) => httpClient.post(`/forums/topic/${topicId}/vote`, { dir }), onSuccess: refreshTopic });
  const delTopic = useMutation({ mutationFn: () => httpClient.delete(`/forums/topic/${topicId}`), onSuccess: () => { qc.invalidateQueries({ queryKey: ['forums'] }); navigate('/forums'); } });
  const addComment = useMutation({ mutationFn: ({ body, parentId }) => httpClient.post(`/forums/topic/${topicId}/comments`, { body, parentId }), onSuccess: () => { setReplyTo(null); setTopComment(''); refreshComments(); refreshTopic(); } });
  const editComment = useMutation({ mutationFn: ({ commentId, body }) => httpClient.patch(`/forums/comment/${commentId}`, { body }), onSuccess: () => { setEditing(null); refreshComments(); } });
  const delComment = useMutation({ mutationFn: (commentId) => httpClient.delete(`/forums/comment/${commentId}`), onSuccess: () => { refreshComments(); refreshTopic(); } });
  const voteComment = useMutation({ mutationFn: ({ commentId, dir }) => httpClient.post(`/forums/comment/${commentId}/vote`, { dir }), onSuccess: refreshComments });

  if (topicQ.isPending) return <div className={styles.center}><div className={styles.loader}><Loader /></div></div>;
  if (topicQ.isError) {
    return (
      <div className={styles.wrap}>
        <header className={styles.head_simple}><Link to="/forums" className={styles.back}>←</Link><h1 className={styles.h1}>{t('ForumsPage.Title')}</h1></header>
        <p className={styles.empty}>{t('ForumsPage.TopicError')}</p>
      </div>
    );
  }

  const topic = topicQ.data;
  const tree = buildTree(commentsQ.data || []);
  const ctx = {
    replyTo, setReplyTo, editing, setEditing,
    onVote: (commentId, dir) => voteComment.mutate({ commentId, dir }),
    onReply: (parentId, body) => addComment.mutate({ body, parentId }),
    onEdit: (commentId, body) => editComment.mutate({ commentId, body }),
    onDelete: (commentId) => delComment.mutate(commentId),
    busy: addComment.isPending || editComment.isPending
  };

  return (
    <div className={styles.wrap}>
      <header className={styles.head_simple}><Link to="/forums" className={styles.back}>←</Link><h1 className={styles.h1}>{t('ForumsPage.Title')}</h1></header>

      <article className={styles.post}>
        <VoteBox score={topic.score} myVote={topic.myVote} onVote={(d) => voteTopic.mutate(d)} />
        <div className={styles.post_main}>
          <h2 className={styles.post_title}>{topic.title}</h2>
          <div className={styles.meta}>
            <Avatar user={topic.author} size={24} />
            <Link to={`/${topic.author?.customId}`} className={styles.meta_name}>{topic.author?.name}</Link>
            <span className={styles.dot}>·</span><span>{timeAgo(topic.createdAt)}</span>
            {topic.updatedAt && topic.updatedAt !== topic.createdAt && <><span className={styles.dot}>·</span><span>{t('ForumsPage.Edited')}</span></>}
          </div>
          {topic.tags?.length > 0 && <div className={styles.tags}>{topic.tags.map((tag) => <span key={tag} className={styles.tag}>{tag}</span>)}</div>}
          <div className={styles.post_body}>{topic.body}</div>
          {topic.isOwner && (
            <div className={styles.owner_actions}>
              <Link to={`/forums/${topicId}/edit`} className={styles.link_action}>{t('ForumsPage.Edit')}</Link>
              <button className={styles.link_action} onClick={() => { if (window.confirm(t('ForumsPage.ConfirmDeleteTopic'))) delTopic.mutate(); }}>{t('ForumsPage.Delete')}</button>
            </div>
          )}
        </div>
      </article>

      <section className={styles.comments_section}>
        <h3 className={styles.comments_head}>{topic.commentCount} {t('ForumsPage.Comments')}</h3>

        <div className={styles.box}>
          <textarea className={styles.textarea} rows={3} value={topComment} onChange={(e) => setTopComment(e.target.value)} placeholder={t('ForumsPage.WriteComment')} />
          <div className={styles.form_actions}>
            <button className={styles.btn_primary} disabled={!topComment.trim() || addComment.isPending} onClick={() => addComment.mutate({ body: topComment, parentId: null })}>{t('ForumsPage.Comment')}</button>
          </div>
        </div>

        {commentsQ.isPending && <div className={styles.center}><div className={styles.loader}><Loader /></div></div>}
        <div className={styles.tree}>
          {tree.map((node) => <CommentNode key={node._id} node={node} myId={myId} t={t} ctx={ctx} />)}
        </div>
      </section>
    </div>
  );
}

/* ----------------------------- page ----------------------------- */
export function ForumsPage() {
  const { topicId } = useParams();
  const loc = useLocation();
  if (loc.pathname === '/forums/new') return <TopicEditor />;
  if (topicId && loc.pathname.endsWith('/edit')) return <TopicEditor topicId={topicId} />;
  if (topicId) return <TopicView topicId={topicId} />;
  return <TopicList />;
}
XEOF
echo "  + frontend/src/pages/ForumsPage/ForumsPage.jsx"

cat > frontend/src/pages/ForumsPage/ForumsPage.module.css << 'XEOF'
.wrap { margin-bottom: var(--content_margin_bottom_global); padding: 4px 14px 0; }

/* headers */
.head { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; padding: 14px 4px 18px; }
.h1 { font-size: 28px; font-weight: 800; letter-spacing: -0.02em; color: var(--color_global); }
.sub { margin-top: 6px; font-size: 14px; color: var(--separator_color_global); }
.head_simple { position: relative; display: flex; align-items: center; gap: 12px; padding: 14px 0 18px; }
.back { font-size: 22px; text-decoration: none; color: var(--color_global); }

/* buttons */
.btn_primary, .btn_muted {
  display: inline-flex; align-items: center; justify-content: center;
  padding: 10px 18px; border-radius: 11px; border: none; cursor: pointer;
  font-size: 14px; font-weight: 700; text-decoration: none; white-space: nowrap;
}
.btn_primary { background-color: var(--hashtag_color_global); color: var(--on_accent_global); }
.btn_primary:hover { background-color: var(--hashtag_color_hover_global); }
.btn_primary:disabled { opacity: 0.55; cursor: default; }
.btn_muted { background-color: transparent; border: var(--border_global); color: var(--separator_color_global); }

.center { height: 200px; display: flex; align-items: center; justify-content: center; }
.loader { width: 21px; height: 21px; }
.empty { color: var(--separator_color_global); padding: 18px 4px; }

/* topic list */
.topics { list-style: none; display: flex; flex-direction: column; gap: 10px; }
.topic { display: flex; gap: 14px; padding: 16px; border-radius: 14px; background-color: var(--filling_background-color_global); border: var(--border_global); }
.listscore { min-width: 34px; text-align: center; font-weight: 800; font-size: 16px; color: var(--separator_color_global); align-self: center; }
.topic_main { min-width: 0; flex: 1; }
.topic_title { font-size: 17px; font-weight: 700; color: var(--color_global); text-decoration: none; }
.topic_title:hover { color: var(--hashtag_color_global); }
.topic_snip { margin-top: 5px; font-size: 14px; line-height: 1.45; color: var(--separator_color_global); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

/* meta line */
.meta { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; margin-top: 9px; font-size: 13px; color: var(--separator_color_global); }
.meta_name { color: var(--color_global); font-weight: 600; text-decoration: none; }
.meta_name:hover { color: var(--hashtag_color_global); }
.dot { opacity: 0.6; }
.tags { display: flex; flex-wrap: wrap; gap: 6px; margin: 12px 0; }
.tag { font-size: 12px; font-weight: 600; color: var(--hashtag_color_global); background-color: color-mix(in srgb, var(--hashtag_color_global) 12%, transparent); border-radius: 7px; padding: 3px 9px; }

/* vote box */
.vote { display: flex; flex-direction: column; align-items: center; gap: 2px; min-width: 34px; }
.varrow { background: none; border: none; cursor: pointer; font-size: 13px; line-height: 1; color: var(--separator_color_global); padding: 2px; }
.varrow:hover { color: var(--color_global); }
.up_on { color: var(--hashtag_color_global); }
.down_on { color: #e24b4a; }
.vscore { font-weight: 800; font-size: 15px; color: var(--color_global); }
.vpos { color: var(--hashtag_color_global); }
.vneg { color: #e24b4a; }

/* topic post */
.post { display: flex; gap: 14px; padding: 20px; border-radius: 16px; background-color: var(--filling_background-color_global); border: var(--border_global); }
.post_main { min-width: 0; flex: 1; }
.post_title { font-size: 23px; font-weight: 800; letter-spacing: -0.01em; color: var(--color_global); }
.post_body { margin-top: 14px; font-size: 15px; line-height: 1.6; color: var(--color_global); white-space: pre-wrap; word-break: break-word; }
.owner_actions { display: flex; gap: 14px; margin-top: 16px; }
.link_action { background: none; border: none; cursor: pointer; font-size: 13px; font-weight: 600; color: var(--separator_color_global); padding: 0; text-decoration: none; }
.link_action:hover { color: var(--hashtag_color_global); }

/* comments */
.comments_section { margin-top: 22px; }
.comments_head { font-size: 16px; font-weight: 800; color: var(--color_global); margin-bottom: 14px; }
.box { margin: 10px 0 4px; }
.tree { margin-top: 18px; display: flex; flex-direction: column; gap: 4px; }
.cnode { padding-top: 8px; }
.comment { display: flex; gap: 12px; }
.comment_main { min-width: 0; flex: 1; }
.comment_body { margin-top: 5px; font-size: 14px; line-height: 1.55; color: var(--color_global); white-space: pre-wrap; word-break: break-word; }
.comment_actions { display: flex; gap: 14px; margin-top: 7px; }
.deleted { font-size: 14px; font-style: italic; color: var(--separator_color_global); padding: 4px 0; }
.children { margin-left: 16px; padding-left: 14px; border-left: var(--border_global); margin-top: 2px; }

/* forms */
.form { display: flex; flex-direction: column; }
.label { font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--separator_color_global); margin: 14px 0 7px; }
.input, .textarea {
  width: 100%; background-color: var(--filling_background-color_global); border: var(--border_global);
  border-radius: 11px; padding: 12px 14px; color: var(--color_global); font-size: 15px; font-family: inherit;
  outline: none; transition: border-color 120ms ease;
}
.input:focus, .textarea:focus { border-color: color-mix(in srgb, var(--hashtag_color_global) 55%, transparent); }
.textarea { resize: vertical; line-height: 1.5; }
.form_actions { display: flex; align-items: center; gap: 10px; margin-top: 14px; }
.error { color: #e24b4a; font-size: 13px; margin-top: 12px; }

/* avatars */
.avatar { border-radius: 50%; object-fit: cover; display: block; flex-shrink: 0; }
.avatar_empty { display: inline-flex; align-items: center; justify-content: center; background-color: var(--item_hover_global); }
.avatar_empty svg { width: 60%; height: 60%; fill: var(--fill_no_avatar_global); }
XEOF
echo "  + frontend/src/pages/ForumsPage/ForumsPage.module.css"

cat > frontend/src/pages/ForumsPage/index.js << 'XEOF'
export { ForumsPage } from "./ForumsPage";
XEOF
echo "  + frontend/src/pages/ForumsPage/index.js"

echo "  wiring routes, sidebar, collections, locales..."
node << 'NODE_RUN_EOF'
import fs from 'fs';

const F = 'frontend';
const BE = 'backend';

function patch(path, fn) {
  if (!fs.existsSync(path)) { console.log('  (missing, skip)', path); return; }
  const s = fs.readFileSync(path, 'utf8');
  const o = fn(s);
  if (o !== s) { fs.writeFileSync(path, o); console.log('  patched', path); }
  else console.log('  (already done)', path);
}

// 1. register collections
patch(BE + '/src/core/engine/db/initializeCollections.js', (s) => {
  if (!s.includes('FORUM_TOPIC_SCHEMA')) {
    s = s.replace(
      "} from '../../../modules/game/game.schema.js';",
      "} from '../../../modules/game/game.schema.js';\nimport {\n    FORUM_TOPIC_SCHEMA,\n    FORUM_TOPIC_INDEXES,\n    FORUM_COMMENT_SCHEMA,\n    FORUM_COMMENT_INDEXES\n} from '../../../modules/forum/forum.schema.js';"
    );
  }
  if (!s.includes("'forumTopics'")) {
    s = s.replace(
      "await upsertCollection(db, 'gameQueue', GAME_QUEUE_SCHEMA, GAME_QUEUE_INDEXES);",
      "await upsertCollection(db, 'gameQueue', GAME_QUEUE_SCHEMA, GAME_QUEUE_INDEXES);\n\n    await upsertCollection(db, 'forumTopics', FORUM_TOPIC_SCHEMA, FORUM_TOPIC_INDEXES);\n    await upsertCollection(db, 'forumComments', FORUM_COMMENT_SCHEMA, FORUM_COMMENT_INDEXES);"
    );
  }
  return s;
});

// 2. pages barrel
patch(F + '/src/pages/index.js', (s) =>
  s.includes('ForumsPage') ? s :
    s.replace('export { GamesPage } from "./GamesPage";', 'export { GamesPage } from "./GamesPage";\nexport { ForumsPage } from "./ForumsPage";')
);

// 3. App.jsx import + routes
patch(F + '/src/app/App.jsx', (s) => {
  if (!s.includes('ForumsPage')) {
    s = s.replace('  GamesPage,\n  NotFoundPage,', '  GamesPage,\n  ForumsPage,\n  NotFoundPage,');
  }
  if (!s.includes('path="/forums"')) {
    const anchor = '<Route path="/games/:gameType" element={<GamesPage />} />';
    const add = anchor +
      '\n              <Route path="/forums" element={<ForumsPage />} />' +
      '\n              <Route path="/forums/new" element={<ForumsPage />} />' +
      '\n              <Route path="/forums/:topicId" element={<ForumsPage />} />' +
      '\n              <Route path="/forums/:topicId/edit" element={<ForumsPage />} />';
    s = s.replace(anchor, add);
  }
  return s;
});

// 4. sidebar nav item
patch(F + '/src/widgets/SideMenuDesktop/SideMenuDesktop.jsx', (s) => {
  if (s.includes('styles.forums')) return s;
  const li =
    '<li className={styles.forums}>\n' +
    '          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">\n' +
    '            <path d="M4 5.5h16a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5H9l-4 3.5V16.5H4A1.5 1.5 0 0 1 2.5 15V7A1.5 1.5 0 0 1 4 5.5Z" />\n' +
    '            <line x1="6.5" y1="9.5" x2="17.5" y2="9.5" />\n' +
    '            <line x1="6.5" y1="12.5" x2="13.5" y2="12.5" />\n' +
    '          </svg>\n' +
    '          <p>{t("SideMenuDesktop.Forums")}</p>\n' +
    '          <Link to="/forums"></Link>\n' +
    '        </li>\n        ';
  return s.replace('<li className={styles.photo}>', li + '<li className={styles.photo}>');
});

// 5. sidebar css
patch(F + '/src/widgets/SideMenuDesktop/SideMenuDesktop.module.css', (s) =>
  s.includes('.forums svg') ? s :
    s + '\n\n/* forums nav item (added) */\n.forums svg {\n  width: 24px;\n  height: 24px;\n  stroke: var(--stroke_global);\n  fill: none;\n}\n'
);

// 6. locales
const ns = {
  en: { Title: "Forums", Subtitle: "Start a topic and discuss with the community.", NewTopic: "New topic", EditTopic: "Edit topic", NoTopics: "No topics yet — be the first to start one.", CommentsShort: "comments", Comments: "Comments", Comment: "Comment", Reply: "Reply", Edit: "Edit", Delete: "Delete", Save: "Save", Publish: "Publish", Cancel: "Cancel", Edited: "edited", DeletedComment: "[deleted]", WriteComment: "Write a comment…", WriteReply: "Write a reply…", TitleField: "Title", BodyField: "Body", TagsField: "Tags", TitlePlaceholder: "A clear, specific title", BodyPlaceholder: "Share your thoughts, a question, or a discussion starter…", TagsPlaceholder: "Comma-separated, e.g. general, help, ideas", ConfirmDeleteTopic: "Delete this topic and all its comments?", ConfirmDeleteComment: "Delete this comment?", TopicError: "This topic could not be loaded.", SaveError: "Something went wrong. Please try again." },
  ru: { Title: "Форумы", Subtitle: "Создайте тему и обсудите её с сообществом.", NewTopic: "Новая тема", EditTopic: "Редактировать тему", NoTopics: "Пока нет тем — создайте первую.", CommentsShort: "комм.", Comments: "Комментарии", Comment: "Комментировать", Reply: "Ответить", Edit: "Изменить", Delete: "Удалить", Save: "Сохранить", Publish: "Опубликовать", Cancel: "Отмена", Edited: "изменено", DeletedComment: "[удалено]", WriteComment: "Напишите комментарий…", WriteReply: "Напишите ответ…", TitleField: "Заголовок", BodyField: "Текст", TagsField: "Теги", TitlePlaceholder: "Чёткий и понятный заголовок", BodyPlaceholder: "Поделитесь мыслями, вопросом или темой для обсуждения…", TagsPlaceholder: "Через запятую, напр. общее, помощь, идеи", ConfirmDeleteTopic: "Удалить эту тему и все комментарии?", ConfirmDeleteComment: "Удалить этот комментарий?", TopicError: "Не удалось загрузить тему.", SaveError: "Что-то пошло не так. Попробуйте ещё раз." }
};
const nav = { en: "Forums", ru: "Форумы" };
for (const lang of ['en', 'ru']) {
  const p = F + '/public/locales/' + lang + '/translation.json';
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  j.SideMenuDesktop = j.SideMenuDesktop || {};
  j.SideMenuDesktop.Forums = nav[lang];
  j.ForumsPage = { ...(j.ForumsPage || {}), ...ns[lang] };
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
}
console.log('  + locales merged (en, ru)');
NODE_RUN_EOF

echo ""
echo "Done. Forums feature applied."
