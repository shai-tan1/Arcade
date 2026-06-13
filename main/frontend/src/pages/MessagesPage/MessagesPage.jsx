// frontend/src/pages/MessagesPage/MessagesPage.jsx

import { useEffect, useRef, useState } from 'react';
import { useParams, Link, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon, EnterIcon } from '../../shared/ui';

import styles from './MessagesPage.module.css';

function formatTime(value) {
  if (!value) return '';
  const date = new Date(value);
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function Avatar({ user }) {
  if (user?.avatarUri) {
    return <img className={styles.avatar} src={(/^https?:\/\//.test(user.avatarUri) ? user.avatarUri : API_BASE_URL + user.avatarUri)} alt={user.name} />;
  }
  return (
    <span className={`${styles.avatar} ${styles.avatar_empty}`}>
      <NoAvatarIcon />
    </span>
  );
}

/* ----------------------------- Conversation list ----------------------------- */
function ConversationList() {
  const { t } = useTranslation();

  const { data, isPending, isError } = useQuery({
    queryKey: ['messages', 'conversations'],
    queryFn: () => httpClient.get('/messages'),
    retry: false
  });

  if (isPending) {
    return (
      <div className={styles.center_loader}>
        <div className={styles.loader}><Loader /></div>
      </div>
    );
  }

  if (isError) {
    return <p className={styles.empty}>{t('MessagesPage.LoadError')}</p>;
  }

  if (!data || data.length === 0) {
    return <p className={styles.empty}>{t('MessagesPage.NoConversations')}</p>;
  }

  return (
    <ul className={styles.conversation_list}>
      {data.map((conv) => (
        <li key={conv.user?._id || Math.random()} className={styles.conversation_item}>
          <Link to={`/messages/${conv.user?.customId}`} className={styles.conversation_link}>
            <div className={styles.avatar_wrap}>
              <Avatar user={conv.user} />
              {conv.user?.status?.isOnline && <span className={styles.online_dot} />}
            </div>
            <div className={styles.conversation_text}>
              <div className={styles.conversation_top}>
                <span className={styles.conversation_name}>{conv.user?.name || t('MessagesPage.Unknown')}</span>
                <span className={styles.conversation_time}>{formatTime(conv.lastMessage?.createdAt)}</span>
              </div>
              <p className={styles.conversation_preview}>{conv.lastMessage?.text}</p>
            </div>
            {conv.unreadCount > 0 && <span className={styles.unread_badge}>{conv.unreadCount}</span>}
          </Link>
        </li>
      ))}
    </ul>
  );
}

/* ----------------------------- Single chat thread ----------------------------- */
function ChatThread({ userId }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();

  const [text, setText] = useState('');
  const bottomRef = useRef(null);

  const { data, isPending, isError } = useQuery({
    queryKey: ['messages', 'thread', userId],
    queryFn: () => httpClient.get(`/messages/${userId}`),
    retry: false
  });

  const sendMutation = useMutation({
    mutationFn: (body) => httpClient.post('/messages', body),
    onSuccess: () => {
      setText('');
      queryClient.invalidateQueries({ queryKey: ['messages', 'thread', userId] });
      queryClient.invalidateQueries({ queryKey: ['messages', 'conversations'] });
    }
  });

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [data?.messages?.length]);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed || !data?.user?._id || sendMutation.isPending) return;
    sendMutation.mutate({ receiverId: data.user._id, text: trimmed });
  };

  const handleKeyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSend();
    }
  };

  if (isPending) {
    return (
      <div className={styles.center_loader}>
        <div className={styles.loader}><Loader /></div>
      </div>
    );
  }

  if (isError) {
    return (
      <div className={styles.thread}>
        <div className={styles.thread_header}>
          <button className={styles.back_button} onClick={() => navigate('/messages')}>←</button>
          <span className={styles.conversation_name}>{t('MessagesPage.Unknown')}</span>
        </div>
        <p className={styles.empty}>{t('MessagesPage.LoadError')}</p>
      </div>
    );
  }

  const myId = authorizedUser?._id;

  return (
    <div className={styles.thread}>
      <div className={styles.thread_header}>
        <button className={styles.back_button} onClick={() => navigate('/messages')} aria-label="Back">←</button>
        <div className={styles.avatar_wrap}>
          <Avatar user={data.user} />
          {data.user?.status?.isOnline && <span className={styles.online_dot} />}
        </div>
        <Link to={`/${data.user?.customId}`} className={styles.conversation_name}>{data.user?.name}</Link>
      </div>

      <div className={styles.messages_scroll}>
        {data.messages.length === 0 && (
          <p className={styles.empty}>{t('MessagesPage.NoMessages')}</p>
        )}
        {data.messages.map((message) => {
          const isOwn = String(message.senderId) === String(myId);
          return (
            <div
              key={message._id}
              className={isOwn ? `${styles.bubble} ${styles.bubble_own}` : styles.bubble}
            >
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
          placeholder={t('MessagesPage.TypeMessage')}
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
    </div>
  );
}

/* ----------------------------- Page ----------------------------- */
export function MessagesPage() {
  const { userId } = useParams();
  const { t } = useTranslation();

  return (
    <div className={styles.messages_page}>
      <div className={styles.title}>
        <h1>{t('MessagesPage.Messages')}</h1>
      </div>
      {userId ? <ChatThread userId={userId} /> : <ConversationList />}
    </div>
  );
}
