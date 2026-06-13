//HashtagPage.jsx

import { useRef, useCallback } from 'react';
import { useParams } from 'react-router-dom';
import { useInfiniteQuery } from '@tanstack/react-query';

import { useAuthData } from '../../features';

import { Loader } from '../../shared/ui';
import { NotFoundPage } from '../../pages';
import { PostPreview } from '../../widgets';
import { httpClient } from '../../shared/api';

import styles from './HashtagPage.module.css';

export function HashtagPage() {
  const { tag } = useParams();
  const link = '/posts/hashtags';

  // authorized user
  const { authorizedUser } = useAuthData();
  // authorized user

  const getPostsPage = async ({ pageParam: cursor, limitPosts = 5 }) => {
    const authId = authorizedUser?._id;
    const params = { limit: limitPosts, tag };

    // Add the authorized user ID to Query Parameters
    if (authId) {
      params.authorizedUserId = authId;
    }
    // /Add the authorized user ID to Query Parameters

    if (cursor) {
      params.cursor = cursor;
    }
    const response = await httpClient.get(link, params);
    return response;
  };

  const {
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    data,
    isPending,
    isSuccess,
    error,
  } = useInfiniteQuery({
    queryKey: ['posts', 'hashtagPosts', tag, authorizedUser?._id],
    queryFn: getPostsPage,
    initialPageParam: null,
    getNextPageParam: (lastPage) => lastPage.nextCursor,
  });

  console.log(authorizedUser?._id)

  const intObserver = useRef(null);
  const lastPostRefCallback = useCallback(
    (post) => {
      if (isFetchingNextPage || isPending) return;
      if (intObserver.current) intObserver.current.disconnect();
      intObserver.current = new IntersectionObserver((posts) => {
        if (posts[0].isIntersecting && hasNextPage) {
          fetchNextPage();
        }
      });
      if (post) intObserver.current.observe(post);
    },

    [isFetchingNextPage, isPending, fetchNextPage, hasNextPage]
  );

  console.log(isFetchingNextPage)

  const posts = data?.pages.flatMap((page) =>
    page.posts.map((post, index) => {

      if (page.posts.length === index + 1) {
        return (
          <PostPreview
            ref={lastPostRefCallback}
            data={post}
            key={post._id}
          />
        );
      }
      return (
        <PostPreview
          data={post}
          key={post._id}
        />
      );
    })
  );

  if (error) {
    return <div className={styles.error}>Error loading posts: {error.message}</div>;
  }


  return (
    <div className={styles.likes_page}>
      <div className={styles.title}>
        <h1>#{tag}</h1>
      </div>

      <div className={styles.posts_wrap}>
        {isSuccess && data?.pages[0]?.posts?.length === 0 && (
          <NotFoundPage />
        )}

        {isPending && (
          <div className={styles.loader_first_loading}>
            <div className={styles.loader}>
              <Loader />
            </div>
          </div>
        )}

        {isSuccess && posts}

        {isFetchingNextPage && (
          <div className={styles.loader_infinite_scroll}>
            <div className={styles.loader}>
              <Loader />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}