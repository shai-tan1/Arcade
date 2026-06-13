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
