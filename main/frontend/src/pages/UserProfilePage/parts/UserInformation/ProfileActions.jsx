// frontend/src/pages/UserProfilePage/parts/UserInformation/ProfileActions.jsx

import { Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../../../shared/api';
import styles from './ProfileActions.module.css';

export function ProfileActions({ profileCustomId, profileUserId }) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const statusQuery = useQuery({
    queryKey: ['friends', 'status', profileCustomId],
    queryFn: () => httpClient.get(`/friends/status/${profileCustomId}`),
    enabled: !!profileCustomId,
    retry: false
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['friends'] });
  };

  const addMutation = useMutation({
    mutationFn: () => httpClient.post('/friends/request', { userId: profileUserId }),
    onSuccess: invalidate
  });
  const acceptMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.post(`/friends/${friendshipId}/accept`),
    onSuccess: invalidate
  });
  const removeMutation = useMutation({
    mutationFn: (friendshipId) => httpClient.delete(`/friends/${friendshipId}`),
    onSuccess: invalidate
  });

  const status = statusQuery.data?.status;
  const friendshipId = statusQuery.data?.friendshipId;

  // Hide entirely while loading, on error, or on your own profile.
  if (statusQuery.isPending || statusQuery.isError || status === 'self') {
    return null;
  }

  return (
    <div className={styles.actions}>
      <Link className={styles.message} to={`/messages/${profileCustomId}`}>
        {t('ProfileActions.Message')}
      </Link>

      {status === 'none' && (
        <button
          className={styles.primary}
          onClick={() => addMutation.mutate()}
          disabled={addMutation.isPending}
        >
          {t('ProfileActions.AddFriend')}
        </button>
      )}

      {status === 'outgoing' && (
        <button className={styles.muted} disabled>
          {t('ProfileActions.Requested')}
        </button>
      )}

      {status === 'incoming' && (
        <button
          className={styles.primary}
          onClick={() => acceptMutation.mutate(friendshipId)}
        >
          {t('ProfileActions.Accept')}
        </button>
      )}

      {status === 'friends' && (
        <button
          className={styles.muted}
          onClick={() => removeMutation.mutate(friendshipId)}
        >
          {t('ProfileActions.Friends')}
        </button>
      )}
    </div>
  );
}
