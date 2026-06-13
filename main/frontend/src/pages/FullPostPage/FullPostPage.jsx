// FullPostPage.jsx

import {
  useState,
  useRef,
  useEffect
} from 'react';
import {
  useQuery,
  useQueryClient
} from '@tanstack/react-query';
import {
  Link,
  useNavigate
} from 'react-router-dom';
import {
  useDispatch,
  useSelector
} from 'react-redux';
import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from "../../features";
import {
  NoAvatarIcon,
  ThreeDotsIcon,
  CrystalIcon,
  EyeIcon,
  RepostIcon,
  BookmarkIcon,
  LinkIcon,
  LikeIcon,
  MessagesIcon,
  Loader,
  PulseLineIcon,
  GifInCircleIcon,
  WordGifIcon,
  UserOnlineStatusCircleIcon
} from '../../shared/ui';
import { NotFoundPage } from '../../pages';
import {
  setShowAccessModal
} from '../../features/accessModal/accessModalSlice';
import {
  formatLinksInText,
  formatLongNumber,
  isSamePostDate
} from '../../shared/helpers';
import {
  useUserStatus,
  useFormattedPostDate
} from '../../shared/hooks';

import styles from './FullPostPage.module.css';

export function FullPostPage() {

  // authorized user
  const { authorizedUser } = useAuthData();
  // /authorized user

  // checking user log in
  const logInStatus = useSelector((state) => state.logInStatus)
  // /checking user log in

  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const queryClient = useQueryClient();
  const navigateTo = useNavigate();
  const dispatch = useDispatch();
  const [userId, setUserId] = useState();
  const linkToUserProfile = userId && window.location.origin + '/' + userId;
  const { t } = useTranslation();
  const { postId } = useParams();

  useEffect(() => {
    // check that the post ID exists before sending the request.
    if (postId) {
      httpClient.post(`/posts/${postId}/view`)
        .then(() => {
          // queryClient.invalidateQueries({ queryKey: ['post', postId] });
        })
        .catch(err => {
          console.error("Error during view increment:", err);
        });
    }
  }, [postId]);

  // Dynamic generation of request URL
  const authId = authorizedUser?._id;
  let queryUrl = `/posts/${postId}`;
  if (authId) {
    // If the user is authorized, add his ID to the Query Parameter
    queryUrl += `?authorizedUserId=${authId}`;
  }

  const post = useQuery({
    // Add authId to queryKey for retrieval when status changes
    queryKey: ['posts', 'fullPostPage', postId, authId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () =>
      // Using dynamic queryUrl
      httpClient.get(queryUrl).then((response) => {
        return response;
      }),
  });

  const { userOnline } = useUserStatus(post?.data?.user?.customId, { delay: 100 });

  const userAvatar = (/^https?:\/\//.test(post?.data?.user?.avatarUri) ? post?.data?.user?.avatarUri : API_BASE_URL + post?.data?.user?.avatarUri);
  const mainImage = (/^https?:\/\//.test(post?.data?.mainImageUri) ? post?.data?.mainImageUri : API_BASE_URL + post?.data?.mainImageUri);

  // Initializing states for likes
  const [userLiked, setUserLiked] = useState(false);
  const [numberLiked, setNumberLiked] = useState(0);

  // Synchronizing local states with data from the request
  useEffect(() => {
    setUserId(post?.data?.user?.customId);
    if (post.isSuccess && post.data) {

      setUserLiked(post.data.isLikedByMe || false);
      setNumberLiked(post.data.likesCount || 0);
    }
  }, [post.data, post.isSuccess, authId]); // Dependency on authId (login/logout)

  // Logic for adding a like (Optimistic Update)
  const onClickAddLike = async () => {
    // Authorization check
    if (!authorizedUser) {
      dispatch(setShowAccessModal(true));
      return;
    }

    // Saving the previous state for rollback
    const currentlyLiked = userLiked;

    // 1. Optimistic UI update
    setUserLiked(!currentlyLiked);
    setNumberLiked(currentlyLiked ? numberLiked - 1 : numberLiked + 1);

    try {
      // 2. Executing a request (PATCH without body)
      await httpClient.patch(`/posts/${postId}/like`);

      // 3. Invalidate requests to get fresh data with status and counter
      queryClient.invalidateQueries({
        queryKey: ['posts', 'fullPostPage', postId],
      });
      queryClient.invalidateQueries({
        queryKey: ['posts'],
      });

    } catch (error) {
      // 4. Rollback on error
      setUserLiked(currentlyLiked);
      setNumberLiked(currentlyLiked ? numberLiked + 1 : numberLiked - 1);
      // Force refresh for synchronization if optimistic update fails
      queryClient.invalidateQueries({
        queryKey: ['posts', 'fullPostPage', postId],
      });
    }
  };
  // /onClickAddLike

  const onClickDeletePost = async (event) => {
    event.preventDefault();
    if (window.confirm(t("FullPostPage.DeletePostQuestion"))) {
      await httpClient.delete(`/posts/${postId}`);
      navigateTo('/');
      queryClient.invalidateQueries({
        queryKey: ['posts'],
      });
    }
  };

  const onClickDeleteAllPosts = async (event) => {
    event.preventDefault();
    if (window.confirm(t("FullPostPage.DeleteAllUserPostsQuestion"))) {
      await httpClient.delete(`/posts/user/${userId}`);
      navigateTo('/');
      queryClient.invalidateQueries({
        queryKey: ['posts']
      });
      queryClient.invalidateQueries({
        queryKey: ['users']
      });
    }
  };

  const onClickDeleteUserAccount = async (event) => {
    event.preventDefault();
    if (window.confirm(t('FullPostPage.DeleteAccountQuestion'))) {
      setFadeOutMenuPostOptions(true);
      await httpClient.delete(`/users/${userId}`);
      queryClient.invalidateQueries({
        queryKey: ['posts'],
      });
      queryClient.invalidateQueries({
        queryKey: ['users'],
      });
    }
  };

  // post options, menu
  const menuPostOptions = useRef();
  const [showMenuPostOptions, setShowMenuPostOptions] = useState(false);
  const [fadeOutMenuPostOptions, setFadeOutMenuPostOptions] = useState(false);
  const buttonShowMenuPostOptions = (Visibility) => {
    if (Visibility) {
      setShowMenuPostOptions(true);
    } else {
      setFadeOutMenuPostOptions(true);
    }
  };

  // closing a menu when clicking outside its field
  useEffect(() => {
    if (menuPostOptions.current) {
      const handler = (e) => {
        e.stopPropagation();
        if (!menuPostOptions.current.contains(e.target)) {
          setFadeOutMenuPostOptions(true);
        }
      };
      document.addEventListener('mousedown', handler);
      return () => {
        document.removeEventListener('mousedown', handler);
      };
    }
  });
  // /closing a menu when clicking outside its field
  // /post options, menu

  // format post date
  const created = useFormattedPostDate(post?.data?.createdAt, true);
  const updated = useFormattedPostDate(post?.data?.updatedAt, true);
  // /format post date

  return (
    <>
      {post.isPending &&
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      }
      {post.isError && <NotFoundPage />}
      {post.isSuccess && (
        <div
          className={styles.post}
          data-full-post-page-dark-theme={darkThemeStatus}
        >
          <div className={styles.post_info_top}>
            <div className={styles.post_info_top_user_info_wrap}>
              {post?.data?.user === null ? (
                <div className={styles.user_info}>
                  <div className={styles.no_avatar_icon}>
                    <NoAvatarIcon />
                  </div>
                  <div className={styles.user_name}>
                    <p>{t('PostPreview.UserDeleted')}</p>
                  </div>
                </div>
              ) : (
                <div className={styles.user_info}>
                  <Link to={linkToUserProfile}></Link>
                  {post?.data?.user?.avatarUri ? (
                    <div className={styles.avatar}>
                      {userAvatar?.endsWith('.gif') && authorizedUser?.settings.interface.hideGif ? (
                        <div className={styles.gif_circle_icon}>
                          <GifInCircleIcon />
                        </div>
                      ) : (
                        <img src={userAvatar} alt="user avatar" />
                      )}
                      {(userOnline) && (
                        <div className={styles.user_online_status_circle_icon_avatar}>
                          <UserOnlineStatusCircleIcon />
                        </div>
                      )}
                    </div>
                  ) : (
                    <div className={styles.no_avatar_icon}>
                      <NoAvatarIcon />
                      {(userOnline) && (
                        <div className={styles.user_online_status_circle_icon_no_avatar}>
                          <UserOnlineStatusCircleIcon />
                        </div>
                      )}
                    </div>
                  )}
                  <div className={styles.user_name_user_custom_id_wrap}>
                    <div className={styles.user_name_wrap}>
                      <div className={styles.user_name}>
                        <p>{post?.data?.user?.name}</p>
                      </div>
                      {post?.data?.user?.creator && (
                        <div className={styles.crystal_icon}>
                          <CrystalIcon />
                        </div>
                      )}
                    </div>
                    <div className={styles.user_custom_id}>
                      <p>{'@' + post?.data?.user?.customId}</p>
                    </div>
                  </div>
                </div>
              )}
            </div>
            <button
              className={styles.options}
              onClick={() =>
                logInStatus ?
                  buttonShowMenuPostOptions(!showMenuPostOptions)
                  :
                  dispatch(setShowAccessModal(true))
              }
            >
              <ThreeDotsIcon />
            </button>
            {showMenuPostOptions && (
              <div
                ref={menuPostOptions}
                className={
                  fadeOutMenuPostOptions
                    ? `${styles.options_menu} ${styles.options_menu_fade_out}`
                    : styles.options_menu
                }
                onAnimationEnd={(e) => {
                  if (e.animationName === styles.fadeOut) {
                    setShowMenuPostOptions(false);
                    setFadeOutMenuPostOptions(false);
                  }
                }}
              >
                <ul>
                  {((post?.data.user?._id === authorizedUser?._id && post?.data?.user?._id !== undefined) ||
                    authorizedUser?.creator) && (
                      <>
                        <li>
                          {t('FullPostPage.EditPost')}
                          <Link to={`/posts/${post?.data?._id}/edit`}></Link>
                        </li>
                        <li onClick={onClickDeletePost}>{t('FullPostPage.DeletePost')}</li>
                      </>
                    )}
                  {post?.data?.user?._id !== authorizedUser?._id && authorizedUser?.creator && (
                    <>
                      <li onClick={onClickDeleteAllPosts}>
                        {t('FullPostPage.DeleteAllUserPosts')}
                      </li>
                      <li onClick={onClickDeleteUserAccount}>
                        {t('FullPostPage.DeleteUser')}
                      </li>
                    </>
                  )}
                </ul>
              </div>
            )}
          </div>
          {post?.data?.title && (
            <div className={styles.post_title}>
              <h1>
                {formatLinksInText(post?.data?.title)}
              </h1>
            </div>
          )}

          {/* post publication date   */}
          <div className={
            (created.isCurrentYear
              & updated.isCurrentYear) ?
              `${styles.post_date_views_wrap}
               ${styles.post_date_views_wrap_current_year}`
              :
              styles.post_date_views_wrap
          }>
            <div className={styles.post_date_views}>
              <div className={styles.post_date_wrap}>
                <div className={styles.post_date_creation}>
                  {!isSamePostDate(post?.data.createdAt, post?.data.updatedAt)}
                  {created?.element}
                </div>
                {!isSamePostDate(post?.data.createdAt, post?.data.updatedAt) &&
                  <div className={styles.post_date_update_wrap}>
                    <div className={styles.post_date_separator}><PulseLineIcon /></div>
                    <div className={styles.post_date_update}>
                      <p>{t('FullPostPage.upd')}:</p>
                      {updated?.element}
                    </div>
                  </div>
                }
              </div>
              <div className={styles.post_views_wrap}>
                <div className={styles.post_views}>
                  <EyeIcon />
                  {post?.data?.views > 0 &&
                    <p>{formatLongNumber(post?.data?.views)}</p>}
                </div>
              </div>
            </div>
          </div>
          {/* /post publication date  */}

          {post?.data?.mainImageUri && (
            post?.data?.mainImageUri?.endsWith('.gif') && authorizedUser?.settings.interface.hideGif ? (
              <div className={styles.word_gif_icon_main_image}>
                <WordGifIcon />
              </div>) :
              <div className={styles.post_image}>
                <img src={mainImage} alt="" />
              </div>
          )}

          {post?.data?.text && (
            <div className={styles.post_text}>
              <p>
                {formatLinksInText(post?.data?.text)}
              </p>
            </div>
          )}
          <div className={styles.post_actions_bar_wrap}>
            <div
              onClick={() =>
                !logInStatus &&
                dispatch(setShowAccessModal(true)
                )}
              className={styles.post_actions_bar}
            >
              <button className={styles.link}>
                <LinkIcon />
              </button>
              <button className={styles.repost}>
                <RepostIcon />
              </button>
              <button className={styles.bookmark}>
                <BookmarkIcon />
              </button>
              <button className={styles.messages}>
                <MessagesIcon />
              </button>
              <div className={styles.like_wrap}>
                <button
                  onClick={authorizedUser ?
                    onClickAddLike
                    :
                    null}
                  className={
                    userLiked ?
                      styles.like_liked
                      :
                      styles.like
                  }
                >
                  <LikeIcon />
                </button>
                {numberLiked > 0 && <p>{formatLongNumber(numberLiked)}</p>}
              </div>
            </div>
          </div >
        </div >
      )
      }
    </>
  );
}