// SearchPage.jsx
import {
  useRef,
  useCallback
} from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from "react-i18next";
import { useAuthData } from '../../features';
import { Loader } from '../../shared/ui';
import { PostPreview } from '../../widgets';
import { httpClient } from '../../shared/api';

import styles from './SearchPage.module.css';

export function SearchPage() {
  const { t } = useTranslation();

  const [searchParams] = useSearchParams();

  //Reading the search query from ?q=...
  const searchQuery = searchParams.get('q'); //  

  // authorized user
  const { authorizedUser } = useAuthData();
  // /authorized user

  const getPostsPage = async ({ pageParam: cursor, limitPosts = 5 }) => {
    const authId = authorizedUser?._id;
    const queryParams = {
      limit: limitPosts,
      q: searchQuery, // transmit a search query
    };

    // Add the authorized user ID to Query Parameters
    if (authId) {
      queryParams.authorizedUserId = authId;
    }
    // /Add the authorized user ID to Query Parameters

    // Adding a cursor to the query parameters
    if (cursor) {
      queryParams.cursor = cursor;
    }

    const response = await httpClient.get('/posts/search', queryParams);
    // Expected response: { posts: [...], nextCursor: '...' }
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
    queryKey: ['posts', 'searchPosts', searchQuery, authorizedUser?._id],
    queryFn: ({ pageParam }) => getPostsPage({ pageParam, limitPosts: 5 }),
    initialPageParam: null,
    enabled: !!searchQuery, // The request is executed only if there is a search query
    retry: false,
    refetchOnWindowFocus: false,
    // We get the next cursor from the server response.
    getNextPageParam: (lastPage) => {
      // Return nextCursor (timestamp), if it exists
      return lastPage.nextCursor ? lastPage.nextCursor : undefined;
    },
  });

  // Infinite Scroll Logic
  const intObserver = useRef();
  const lastPostRef = useCallback(
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

  // combine posts from all pages
  const posts = data?.pages.flatMap((page) =>
    page.posts.map((post, index) => {
      // pass the ref only to the last post on the last page
      if (page.posts.length === index + 1 && hasNextPage && !isFetchingNextPage) {
        return <PostPreview ref={lastPostRef} data={post} key={post._id} />;
      }
      return <PostPreview data={post} key={post._id} />;
    })
  );

  if (error) {
    return <div className={styles.error}>Error loading posts: {error.message}</div>;
  }

  const noResults = isSuccess && posts.length === 0;

  return (
    <div className={styles.posts_wrap}>

      <div className={
        (noResults || !searchQuery) ?
          `${styles.title} ${styles.title_no_posts}`
          : styles.title
      }>

        {!isPending && (
          <>
            {(!noResults && searchQuery) && (
              <p><strong>{t("SearchPage.SearchResultsFor")}</strong> {searchQuery}</p>)}

            {!searchQuery && (
              <p><strong> {t("SearchPage.EnterYourSearchTerm")}</strong></p>)}

            {noResults && (
              <p><strong>{t("SearchPage.NothingFoundFor")}</strong> {searchQuery}</p>)}

          </>
        )}

        {!searchQuery && (
          <div className={styles.enter_your_search_term}>
            <p><strong>
              {t("SearchPage.EnterYourSearchTerm")}
            </strong></p>
          </div>
        )}

      </div>

      {/* display the loader only during the first search and when there is a request */}
      {isPending && searchQuery && (
        <div className={styles.loader_first_loading}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}
      {/* No results message */}
      {/* {noResults && (
        <div className={styles.no_posts_message}>
          <p>{t("SearchPage.NothingFoundFor")}</p>
        </div>
      )} */}

      {/* List of posts */}
      {isSuccess && posts}

      {/* Loader for loading the next page */}
      {isFetchingNextPage && (
        <div className={styles.loader_infinite_scroll}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}
    </div>
  );
}