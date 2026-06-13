// UserPagePostsWrap.jsx

import { useRef, useCallback } from 'react';
import { useParams } from 'react-router-dom';
import { useInfiniteQuery } from '@tanstack/react-query';

import { useAuthData } from '../../../../features';

import { Loader } from '../../../../shared/ui';
import { PostPreview } from '../../../../widgets';
import { httpClient } from '../../../../shared/api';

import styles from './UserPagePostsWrap.module.css';

export function UserPagePostsWrap() {
  const { userId } = useParams();
  const link = `/posts/user/${userId}`;

  // authorized user
  const { authorizedUser } = useAuthData();

  const getPostsPage = async ({ pageParam = 1, limitPosts = 5 }) => {
    const authId = authorizedUser?._id;
    const queryParams = { page: pageParam, limit: limitPosts };

    // Add ID to queryParams if the user is authorized
    if (authId) {
      queryParams.authorizedUserId = authId;
    }

    // console.log('Sending request to /posts/user... with queryParams:', queryParams);  
    const response = await httpClient.get(link, queryParams);
    // console.log('Response from /posts/user:', response); 
    return response; // { posts: [], currentPage, totalPages, totalPosts }
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
    // Add ID to queryKey for retrieval when status changes
    queryKey: ['posts', 'userPagePostsWrap', userId, authorizedUser?._id],
    queryFn: ({ pageParam }) => getPostsPage({ pageParam, limitPosts: 5 }),
    initialPageParam: 1,
    retry: false,
    refetchOnWindowFocus: true,
    getNextPageParam: (lastPage) => {
      return lastPage.currentPage < lastPage.totalPages ? lastPage.currentPage + 1 : undefined;
    },
  });

  const intObserver = useRef();
  const lastPostRef = useCallback(
    (post) => {
      if (isFetchingNextPage) return;
      if (intObserver.current) intObserver.current.disconnect();
      intObserver.current = new IntersectionObserver((posts) => {
        if (posts[0].isIntersecting && hasNextPage) {
          fetchNextPage();
        }
      });
      if (post) intObserver.current.observe(post);
    },
    [isFetchingNextPage, fetchNextPage, hasNextPage]
  );

  const posts = data?.pages.flatMap((page) =>
    page.posts.map((post, index) => {
      if (page.posts.length === index + 1) {
        return (
          <PostPreview
            ref={lastPostRef}
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
    <div className={styles.posts_wrap}>
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
      {/* {isSuccess && posts.length === 0 && (
        <p className={styles.no_posts_message}>There are no posts yet..</p>
      )} */}
    </div>
  );
}