// frontend/src/pages/CommunitiesPage/CommunitiesPage.jsx

import { useEffect, useRef, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon, EnterIcon, GroupsIcon } from '../../shared/ui';

import styles from './CommunitiesPage.module.css';

function formatTime(value) {
  if (!value) return '';
  return new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function Avatar({ user }) {
  if (user?.avatarUri) {
    return <img className={styles.avatar} src={API_BASE_URL + user.avatarUri} alt={user.name} />;
  }
  return (
    <span className={`${styles.avatar} ${styles.avatar_empty}`}>
      <NoAvatarIcon />
    </span>
  );
}

/* ----------------------------- List + create ----------------------------- */
function CommunityList() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');

  const { data, isPending, isError } = useQuery({
    queryKey: ['communities', 'list'],
    queryFn: () => httpClient.get('/communities'),
    retry: false
  });

  const createMutation = useMutation({
    mutationFn: (body) => httpClient.post('/communities', body),
    onSuccess: (created) => {
      setName('');
      setDescription('');
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
      if (created?._id) navigate(`/communities/${created._id}`);
    }
  });

  const joinMutation = useMutation({
    mutationFn: (communityId) => httpClient.post(`/communities/${communityId}/join`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['communities', 'list'] })
  });

  const handleCreate = () => {
    const trimmed = name.trim();
    if (!trimmed || createMutation.isPending) return;
    createMutation.mutate({ name: trimmed, description: description.trim() });
  };

  return (
    <div className={styles.list_wrap}>
      <div className={styles.create_box}>
        <input
          className={styles.create_input}
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder={t('CommunitiesPage.NamePlaceholder')}
          maxLength={100}
        />
        <input
          className={styles.create_input}
          value={description}
          onChange={(event) => setDescription(event.target.value)}
          placeholder={t('CommunitiesPage.DescriptionPlaceholder')}
          maxLength={500}
        />
        <button
          className={styles.create_button}
          onClick={handleCreate}
          disabled={!name.trim() || createMutation.isPending}
        >
          {t('CommunitiesPage.Create')}
        </button>
      </div>

      {isPending && (
        <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
      )}

      {isError && <p className={styles.empty}>{t('CommunitiesPage.LoadError')}</p>}

      {!isPending && !isError && data?.length === 0 && (
        <p className={styles.empty}>{t('CommunitiesPage.NoCommunities')}</p>
      )}

      <ul className={styles.community_list}>
        {data?.map((community) => (
          <li key={community._id} className={styles.community_item}>
            <span className={`${styles.avatar} ${styles.avatar_empty}`}><GroupsIcon /></span>
            <div className={styles.community_text}>
              <span className={styles.community_name}>{community.name}</span>
              {community.description && (
                <p className={styles.community_description}>{community.description}</p>
              )}
              <span className={styles.community_meta}>
                {community.membersCount} {t('CommunitiesPage.Members')}
              </span>
            </div>
            {community.isMember ? (
              <Link className={styles.open_button} to={`/communities/${community._id}`}>
                {t('CommunitiesPage.Open')}
              </Link>
            ) : (
              <button
                className={styles.join_button}
                onClick={() => joinMutation.mutate(community._id)}
                disabled={joinMutation.isPending}
              >
                {t('CommunitiesPage.Join')}
              </button>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

/* ----------------------------- Room chat ----------------------------- */
function CommunityRoom({ communityId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();

  const [text, setText] = useState('');
  const bottomRef = useRef(null);

  const communityQuery = useQuery({
    queryKey: ['communities', communityId],
    queryFn: () => httpClient.get(`/communities/${communityId}`),
    retry: false
  });

  const isMember = communityQuery.data?.isMember;

  const messagesQuery = useQuery({
    queryKey: ['communities', communityId, 'messages'],
    queryFn: () => httpClient.get(`/communities/${communityId}/messages`),
    enabled: !!isMember,
    retry: false
  });

  const joinMutation = useMutation({
    mutationFn: () => httpClient.post(`/communities/${communityId}/join`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['communities', communityId] });
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
    }
  });

  const leaveMutation = useMutation({
    mutationFn: () => httpClient.post(`/communities/${communityId}/leave`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['communities', 'list'] });
      navigate('/communities');
    }
  });

  const sendMutation = useMutation({
    mutationFn: (body) => httpClient.post(`/communities/${communityId}/messages`, body),
    onSuccess: () => {
      setText('');
      queryClient.invalidateQueries({ queryKey: ['communities', communityId, 'messages'] });
    }
  });

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messagesQuery.data?.length]);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed || sendMutation.isPending) return;
    sendMutation.mutate({ text: trimmed });
  };

  const handleKeyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSend();
    }
  };

  if (communityQuery.isPending) {
    return <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>;
  }

  if (communityQuery.isError) {
    return (
      <div className={styles.room}>
        <div className={styles.room_header}>
          <button className={styles.back_button} onClick={() => navigate('/communities')}>←</button>
        </div>
        <p className={styles.empty}>{t('CommunitiesPage.LoadError')}</p>
      </div>
    );
  }

  const community = communityQuery.data;
  const myId = authorizedUser?._id;

  return (
    <div className={styles.room}>
      <div className={styles.room_header}>
        <button className={styles.back_button} onClick={() => navigate('/communities')} aria-label="Back">←</button>
        <span className={`${styles.avatar} ${styles.avatar_empty}`}><GroupsIcon /></span>
        <div className={styles.room_header_text}>
          <span className={styles.community_name}>{community.name}</span>
          <span className={styles.community_meta}>
            {community.members?.length || 0} {t('CommunitiesPage.Members')}
          </span>
        </div>
        {isMember && (
          <button
            className={styles.leave_button}
            onClick={() => leaveMutation.mutate()}
            disabled={leaveMutation.isPending}
          >
            {t('CommunitiesPage.Leave')}
          </button>
        )}
      </div>

      {!isMember ? (
        <div className={styles.join_prompt}>
          <p>{t('CommunitiesPage.JoinToChat')}</p>
          <button
            className={styles.join_button}
            onClick={() => joinMutation.mutate()}
            disabled={joinMutation.isPending}
          >
            {t('CommunitiesPage.Join')}
          </button>
        </div>
      ) : (
        <>
          <div className={styles.messages_scroll}>
            {messagesQuery.isPending && (
              <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
            )}
            {messagesQuery.data?.length === 0 && (
              <p className={styles.empty}>{t('CommunitiesPage.NoMessages')}</p>
            )}
            {messagesQuery.data?.map((message) => {
              const isOwn = String(message.senderId) === String(myId);
              return (
                <div
                  key={message._id}
                  className={isOwn ? `${styles.bubble} ${styles.bubble_own}` : styles.bubble}
                >
                  {!isOwn && (
                    <Link to={`/${message.sender?.customId}`} className={styles.bubble_author}>
                      {message.sender?.name || t('CommunitiesPage.Unknown')}
                    </Link>
                  )}
                  <span className={styles.bubble_text}>{message.text}</span>
                  <span className={styles.bubble_time}>{formatTime(message.createdAt)}</span>
                </div>
              );
            })}
            <div ref={bottomRef} />
          </div>

          <div className={styles.composer}>
            <textarea
              className={styles.composer_input}
              value={text}
              onChange={(event) => setText(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder={t('CommunitiesPage.TypeMessage')}
              rows={1}
            />
            <button
              className={styles.send_button}
              onClick={handleSend}
              disabled={!text.trim() || sendMutation.isPending}
              aria-label="Send"
            >
              <EnterIcon />
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/* ----------------------------- Page ----------------------------- */
export function CommunitiesPage() {
  const { communityId } = useParams();
  const { t } = useTranslation();

  return (
    <div className={styles.communities_page}>
      <div className={styles.title}>
        <h1>{t('CommunitiesPage.Communities')}</h1>
      </div>
      {communityId ? <CommunityRoom communityId={communityId} /> : <CommunityList />}
    </div>
  );
}
