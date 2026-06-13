// RecommendedUsers.jsx

import {
  useDispatch,
  useSelector
} from 'react-redux';
import { useQuery } from '@tanstack/react-query';
import { Link, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from '../../features';
import { setShowAccessModal } from '../../features/accessModal/accessModalSlice';
import { ThreeDotsIcon } from '../../shared/ui';
import {
  NoAvatarIcon,
  CrystalIcon,
  GifInCircleIcon,
  Loader,
  UserOnlineStatusCircleIcon
} from '../../shared/ui';

import styles from './RecommendedUsers.module.css';

export function RecommendedUsers() {

  // authorized user
  const {
    authorizedUser,
    isPending: isAuthPending,
    isSuccess: isAuthSuccess } = useAuthData();
  // /authorized user

  // checking user log in
  const logInStatus = useSelector((state) =>
    state.logInStatus)
  // /checking user log in

  const darkThemeStatus = useSelector((state) =>
    state.darkThemeStatus);

  const dispatch = useDispatch();
  const { t } = useTranslation();

  const location = useLocation();

  const users = useQuery({
    queryKey: [
      'users',
      'recommendedUsers',
      location.pathname
    ],

    queryFn: () => {
      const params =
        logInStatus && authorizedUser?.customId
          ? { exclude: authorizedUser?.customId, limit: 4 }
          : { limit: 4 };
      return httpClient.get('/users/', params);
    },
    refetchOnWindowFocus: true,
    retry: false,
  });

  return (
    <div
      className={
        logInStatus
          ? styles.recommended_users
          : `${styles.recommended_users} ${styles.recommended_users_not_authorized_user}`
      }
      data-recommended-users-dark-theme={darkThemeStatus}
    >
      <div className={styles.title}>
        <p>{t('RecommendedUsers.YouMightLike')}</p>
      </div>

      {(users.isPending || (logInStatus && isAuthPending)) && (
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}

      {users.isSuccess && (!logInStatus || isAuthSuccess) &&
        users.data?.map((user, index) => {
          return (
            <div key={index} className={styles.user_wrap}>
              <Link to={'/' + user.customId}></Link>
              <div className={styles.user}>
                <div className={styles.avatar_name_id_wrap}>
                  {user.avatarUri ? (
                    <div className={styles.avatar_wrap}>
                      <div className={styles.avatar}>
                        {user.avatarUri?.endsWith('.gif') && logInStatus && (authorizedUser?.settings.interface.hideGif ?? false) ? (
                          <div className={styles.gif_circle_icon}>
                            <GifInCircleIcon />
                          </div>
                        ) : (
                          <img src={(/^https?:\/\//.test(user.avatarUri) ? user.avatarUri : API_BASE_URL + user.avatarUri)} alt="user avatar" loading="lazy" />
                        )}
                        {user.status?.isOnline ? (
                          <div className={styles.user_online_status_circle_icon}>
                            <UserOnlineStatusCircleIcon />
                          </div>
                        ) : null}
                      </div>
                    </div>
                  ) : (
                    <div className={styles.no_avatar_icon_wrap}>
                      <div className={styles.no_avatar_icon}>
                        <NoAvatarIcon />
                        {user.status?.isOnline ? (
                          <div className={styles.user_online_status_circle_icon}>
                            <UserOnlineStatusCircleIcon />
                          </div>
                        ) : null}
                      </div>
                    </div>
                  )}
                  <div className={styles.name_id_wrap}>
                    {user.name && (
                      <div className={styles.name}>
                        <p>{user.name}</p>
                        {user.creator && (
                          <div className={styles.crystal_icon}>
                            <CrystalIcon />
                          </div>
                        )}
                      </div>
                    )}
                    <div className={styles.id}>
                      <p>@{user.customId}</p>
                    </div>
                  </div>
                </div>
                <button
                  className={styles.options}
                  onClick={() => !logInStatus && dispatch(setShowAccessModal(true))}
                >
                  <ThreeDotsIcon />
                </button>
                <button
                  className={styles.subscribe}
                  onClick={() => !logInStatus && dispatch(setShowAccessModal(true))}
                >
                  {t('RecommendedUsers.Subscribe')}
                </button>
              </div>
            </div>
          );
        })}

      <button className={styles.show_more}>{t('RecommendedUsers.ShowMore')}</button>
    </div>
  );
}