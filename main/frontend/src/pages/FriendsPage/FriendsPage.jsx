// frontend/src/pages/FriendsPage/FriendsPage.jsx

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { Loader, NoAvatarIcon } from '../../shared/ui';

import styles from './FriendsPage.module.css';

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

function UserRow({ user, children }) {
  return (
    <li className={styles.row}>
      <Link to={`/${user.customId}`} className={styles.row_user}>
        <div className={styles.avatar_wrap}>
          <Avatar user={user} />
          {user.status?.isOnline && <span className={styles.online_dot} />}
        </div>
        <div className={styles.row_text}>
          <span className={styles.row_name}>{user.name}</span>
          <span className={styles.row_id}>@{user.customId}</span>
        </div>
      </Link>
      <div className={styles.row_actions}>{children}</div>
    </li>
  );
}

export function FriendsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { authorizedUser } = useAuthData();
  const [query, setQuery] = useState('');

  const friendsQuery = useQuery({
    queryKey: ['friends', 'list'],
    queryFn: () => httpClient.get('/friends'),
    retry: false
  });

  const requestsQuery = useQuery({
    queryKey: ['friends', 'requests'],
    queryFn: () => httpClient.get('/friends/requests'),
    retry: false
  });

  const trimmed = query.trim();
  const searchQuery = useQuery({
    queryKey: ['users', 'search', trimmed],
    queryFn: () => {
      const params = { q: trimmed, limit: 20 };
      if (authorizedUser?.customId) params.exclude = authorizedUser.customId;
      return httpClient.get('/users', params);
    },
    enabled: trimmed.length > 0,
    retry: false
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['friends'] });
    queryClient.invalidateQueries({ queryKey: ['users', 'search'] });
  };

  const addMutation = useMutation({
    mutationFn: (userId) => httpClient.post('/friends/request', { userId }),
    onSuccess: invalidate
  });
  const acceptMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/accept`),
    onSuccess: invalidate
  });
  const declineMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/decline`),
    onSuccess: invalidate
  });
  const removeMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.delete(`/friends/${friendshipId}`),
    onSuccess: invalidate
  });

  const friends = friendsQuery.data || [];
  const incoming = requestsQuery.data?.incoming || [];
  const outgoing = requestsQuery.data?.outgoing || [];

  // Relationship lookup so search results show the right button.
  const friendByUserId = new Map(friends.map((f) => [String(f.user._id), f]));
  const outgoingByUserId = new Map(outgoing.map((r) => [String(r.user._id), r]));
  const incomingByUserId = new Map(incoming.map((r) => [String(r.user._id), r]));

  const renderSearchAction = (user) => {
    const id = String(user._id);
    if (friendByUserId.has(id)) {
      return <Link className={styles.btn_secondary} to={`/messages/${user.customId}`}>{t('FriendsPage.Message')}</Link>;
    }
    if (outgoingByUserId.has(id)) {
      return <button className={styles.btn_muted} disabled>{t('FriendsPage.Requested')}</button>;
    }
    if (incomingByUserId.has(id)) {
      return (
        <button className={styles.btn_primary} onClick={() => acceptMutation.mutate(incomingByUserId.get(id).friendshipId)}>
          {t('FriendsPage.Accept')}
        </button>
      );
    }
    return (
      <button className={styles.btn_primary} onClick={() => addMutation.mutate(user._id)} disabled={addMutation.isPending}>
        {t('FriendsPage.AddFriend')}
      </button>
    );
  };

  return (
    <div className={styles.friends_page}>
      <div className={styles.title}>
        <h1>{t('FriendsPage.Friends')}</h1>
      </div>

      {/* Find people */}
      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('FriendsPage.FindPeople')}</h2>
        <input
          className={styles.search_input}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('FriendsPage.SearchPlaceholder')}
        />
        {trimmed.length > 0 && (
          <ul className={styles.list}>
            {searchQuery.isPending && (
              <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
            )}
            {searchQuery.isSuccess && searchQuery.data.length === 0 && (
              <p className={styles.empty}>{t('FriendsPage.NoResults')}</p>
            )}
            {searchQuery.data?.map((user) => (
              <UserRow key={user._id} user={user}>{renderSearchAction(user)}</UserRow>
            ))}
          </ul>
        )}
      </section>

      {/* Incoming requests */}
      {incoming.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.section_title}>{t('FriendsPage.Requests')}</h2>
          <ul className={styles.list}>
            {incoming.map((r) => (
              <UserRow key={r.friendshipId} user={r.user}>
                <button className={styles.btn_primary} onClick={() => acceptMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Accept')}
                </button>
                <button className={styles.btn_muted} onClick={() => declineMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Decline')}
                </button>
              </UserRow>
            ))}
          </ul>
        </section>
      )}

      {/* Outgoing requests */}
      {outgoing.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.section_title}>{t('FriendsPage.Sent')}</h2>
          <ul className={styles.list}>
            {outgoing.map((r) => (
              <UserRow key={r.friendshipId} user={r.user}>
                <button className={styles.btn_muted} onClick={() => removeMutation.mutate(r.friendshipId)}>
                  {t('FriendsPage.Cancel')}
                </button>
              </UserRow>
            ))}
          </ul>
        </section>
      )}

      {/* My friends */}
      <section className={styles.section}>
        <h2 className={styles.section_title}>{t('FriendsPage.MyFriends')}</h2>
        {friendsQuery.isPending && (
          <div className={styles.center_loader}><div className={styles.loader}><Loader /></div></div>
        )}
        {friendsQuery.isSuccess && friends.length === 0 && (
          <p className={styles.empty}>{t('FriendsPage.NoFriends')}</p>
        )}
        <ul className={styles.list}>
          {friends.map((f) => (
            <UserRow key={f.friendshipId} user={f.user}>
              <Link className={styles.btn_primary} to={`/messages/${f.user.customId}`}>{t('FriendsPage.Message')}</Link>
              <button className={styles.btn_muted} onClick={() => removeMutation.mutate(f.friendshipId)}>
                {t('FriendsPage.Remove')}
              </button>
            </UserRow>
          ))}
        </ul>
      </section>
    </div>
  );
}
