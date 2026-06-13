import { useDispatch, useSelector } from 'react-redux';
import { useQuery } from '@tanstack/react-query';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { setShowAccessModal } from '../../features/accessModal/accessModalSlice';
import { Loader, ThreeDotsIcon } from '../../shared/ui';
import { formatLongNumber } from '../../shared/helpers';

import styles from './CurrentTopics.module.css';

export function CurrentTopics() {
  const dispatch = useDispatch();
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);
  const logInStatus = useSelector((state) => state.logInStatus);
  const { changesAddressBar } = useParams();
  const { t } = useTranslation();

  const topics = useQuery({
    queryKey: ['posts', 'currentTopics', changesAddressBar],
    queryFn: () => {
      const params = { limit: 6 };
       
      return httpClient.get('/hashtags', params);
    },
    refetchOnWindowFocus: true,
    retry: false,
  });
 

  return (
    <div className={styles.current_topics} data-current-topics-dark-theme={darkThemeStatus}>
      <div className={styles.title}>
        <p>{t('CurrentTopics.CurrentTopics')}</p>
      </div>

      {topics.isPending && (
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}

      {topics.isSuccess && topics.data?.length > 0 && (
        topics.data.map((topic) => (

          <div
            key={topic.name}
            className={styles.topic}
          >
            <div className={styles.name}>
              <p>#{topic.name}</p>
            </div>
            <div className={styles.number_post_wrap}>
              <div className={styles.number}>
                <p>{formatLongNumber(topic.quantity)}</p>
              </div>
              <div className={styles.post}>
                <p>
                  {topic.quantity > 1000
                    ? t('CurrentTopics.Posts')
                    : t('CurrentTopics.key', { count: topic.quantity })}
                </p>
              </div>
            </div>
            <button
              className={styles.options}
              onClick={(e) => {
                if (!logInStatus) {
                  e.preventDefault(); // Предотвращаем переход по Link
                  dispatch(setShowAccessModal(true));
                }
              }}
            >
              <ThreeDotsIcon />
            </button>
          <Link to={`/hashtags/${topic.name}`}> </Link>
          </div>
        ))
      )}

      <button className={styles.show_more}>
        {t('CurrentTopics.ShowMore')}
      </button>
    </div>
  );
}