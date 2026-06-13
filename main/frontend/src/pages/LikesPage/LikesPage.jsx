// LikesPage.jsx

import {
  useRef,
  useCallback,
  useMemo
} from "react";
import {
  useParams,
  Navigate
} from "react-router-dom";
import { useInfiniteQuery } from "@tanstack/react-query";
import { useTranslation } from 'react-i18next';

import {
  PostPreview
} from "../../widgets";
import { Loader } from "../../shared/ui";
import { NotFoundPage } from "../../pages";
import { httpClient } from "../../shared/api";

import styles from "./LikesPage.module.css";

export function LikesPage() {

  const { userId } = useParams();
  const { t } = useTranslation();

  const LIMIT_POSTS = 5;
  const link = "/likes/" + userId;

  // Function to get the page, uses cursor for pagination
  const getPostsPage = async (cursor = null) => {
    const params = { limit: LIMIT_POSTS };
    if (cursor) {
      params.cursor = cursor; // Using 'cursor' in the request
    }

    const response = await httpClient.get(link, params);
    // Expected object: { posts: [{}, {}, ...], nextCursor: "2023-10-20T..." | null }
    return response;
  };

  const {
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    data,
    isPending,
    isError,
    error,
    isSuccess
  } = useInfiniteQuery({
    queryKey: ['posts', "LikesPage", userId],
    queryFn: ({ pageParam }) => getPostsPage(pageParam),
    retry: false,
    initialPageParam: null,
    // Retrieving nextCursor from the response
    getNextPageParam: (lastPage) => {
      // lastPage - this is an object { posts: [...], nextCursor: "..." }
      return lastPage.nextCursor || undefined;
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
    [isFetchingNextPage, fetchNextPage, hasNextPage],
  );

  // Use useMemo to create a list of posts
  const posts = useMemo(() => {
    // Using flatMap to extract the posts array from each page
    const allPosts = data?.pages.flatMap((page) => page.posts) || [];

    return allPosts.map((post, index) => {
      // pass ref ONLY to the last post IF there is a next page
      const isLastPost = index === allPosts.length - 1;
      const refToPass = (isLastPost && hasNextPage) ? lastPostRef : null;

      return (
        <PostPreview
          ref={refToPass}
          data={post}
          key={post._id}
        />
      );
    });
  }, [data, lastPostRef, hasNextPage]); 

  const isAccessDeniedError = isError && error?.response?.status === 403;

  // 1. Access check (if the backend returned 403)
  if (isAccessDeniedError) {
    return <Navigate to="/" replace />;
  }

  // 2. Check for other errors (such as 404 if the user does not exist)
  if (isError) {
    return <NotFoundPage />;
  }

  return (
    <div className={styles.likes_page}>

      <div className={
        // Checking for an empty list of posts
        (isSuccess && posts.length === 0) ?
          `${styles.title} ${styles.title_no_posts}`
          : styles.title
      }>
        <h1>{t("LikesPage.LikedPosts")}</h1>
      </div>

      <div className={styles.posts_wrap}>

        {isPending &&
          <div className={styles.loader_first_loading}>
            <div className={styles.loader}>
              <Loader />
            </div>
          </div>
        }

        {/* Message if there are no likes */}
        {/* {isSuccess && posts.length === 0 && (
          <p className={styles.no_likes_message}>
            {t('LikesPage.NoLikes')}
          </p>
        )} */}

        {/* Post output */}
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