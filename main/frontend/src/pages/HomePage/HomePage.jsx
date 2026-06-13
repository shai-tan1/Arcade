// HomePage.jsx

import { useRef, useCallback } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';

import { useAuthData } from '../../features';

import { Loader } from '../../shared/ui';
import { PostPreview, PostSourceMenu } from '../../widgets';
import { httpClient } from '../../shared/api';

import styles from './HomePage.module.css';

export function HomePage() {

  // authorized user
  const { authorizedUser } = useAuthData();
  // /authorized user

  const getPostsPage = async ({ pageParam = 1, limitPosts = 5 }) => {
    const authId = authorizedUser?._id;
    const queryParams = { page: pageParam, limit: limitPosts };

    // Adding a user ID to Query Parameters
    if (authId) {
      queryParams.authorizedUserId = authId;
    }

    // console.log('Sending request with queryParams:', queryParams); 
    const response = await httpClient.get('/posts', queryParams);
    // console.log('Response from /posts:', response); 
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
    queryKey: ['posts', 'homePagePosts', authorizedUser?._id], // ID in queryKey to reset on entry/exit
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
      <PostSourceMenu />
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
      {isSuccess && posts.length === 0 && (
        <p className={styles.no_posts_message}>There are no posts yet..</p>
      )}
    </div>
  );
}