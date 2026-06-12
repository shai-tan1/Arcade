import {
  useState,
  useEffect,
  useRef
} from 'react';
import {
  useDispatch,
  useSelector
} from 'react-redux';
import {
  useParams,
  Link
} from 'react-router-dom';
import {
  useQuery,
  useMutation,
  useQueryClient
} from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../../../shared/api';
import { API_BASE_URL } from '../../../../shared/constants';
import { useAuthData } from '../../../../features';
import {
  setShowMoreAboutUserModal,
  setUserId
} from '../../../../features/moreAboutUserModal/moreAboutUserModalSlice';
import {
  useFormattedLastSeenDate,
  useFormattedLastSeenDateShort
} from '../../../../shared/hooks';
import { setShowAccessModal } from "../../../../features/accessModal/accessModalSlice";
import {
  LoadingBar,
  NoAvatarIcon,
  DeleteIcon,
  CameraIcon,
  AcceptIcon,
  CrystalIcon,
  ThreeDotsIcon,
  GifInCircleIcon,
  WordGifIcon,
  Loader,
  UserOnlineStatusCircleIcon
} from '../../../../shared/ui';
import { NotFoundPage } from '../../../../pages';
import { convertImage } from '../../../../shared/utils';
import { formatLinksInText } from '../../../../shared/helpers';

import { ProfileActions } from './ProfileActions';

import styles from './UserInformation.module.css';

export function UserInformation() {

  const {
    authorizedUser,
    isPending: isAuthPending,
    isSuccess: isAuthSuccess
  } = useAuthData();

  const logInStatus = useSelector(
    (state) => state.logInStatus
  );

  const darkThemeStatus = useSelector(
    (state) => state.darkThemeStatus
  );

  const dispatch = useDispatch();
  const queryClient = useQueryClient();
  const { t } = useTranslation();

  // user options, menu
  const menuUserOptions = useRef();

  const [
    showMenuUserOptions,
    setShowMenuUserOptions
  ] = useState(false);

  const [
    menuUserOptionsFadeOut,
    setMenuUserOptionsFadeOut
  ] = useState(false);

  const buttonShowMenuPostOptions = (Visibility) => {
    if (Visibility) {
      setShowMenuUserOptions(true);
    } else {
      setMenuUserOptionsFadeOut(true);
    }
  };

  // closing a menu when clicking outside its field
  useEffect(() => {
    if (menuUserOptions.current) {
      const handler = (event) => {
        event.stopPropagation();
        if (!menuUserOptions.current.contains(event.target)) {
          setMenuUserOptionsFadeOut(true);
        }
      };
      document.addEventListener('mousedown', handler);
      return () => document.removeEventListener('mousedown', handler);
    }
  },);
  // /closing a menu when clicking outside its field

  const { userId } = useParams();
  const authorizedUserAccessCheck = authorizedUser?.creator || authorizedUser?.customId === userId;

  // checking whether the user has posts
  const [userHavePosts, setUserHavePost] = useState(false);
  const userPosts = useQuery({
    queryKey: ['posts', 'userInformationUserHavePosts', userId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () => httpClient.get(`/posts/user/${userId}`).then((response) => response),
  });

  useEffect(() => {
    setUserHavePost(userPosts.data?.totalPosts > 0 ? true : false);
  }, [userPosts]);

  const user = useQuery({
    queryKey: ['users', 'userProfilePageUserData', userId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () => httpClient.get(`/users/${userId}`).then((response) => response),
  });

  // banner useState
  const [
    databaseHaveBanner,
    setDatabaseHaveBanner
  ] = useState(true);

  const [
    databaseBannerUri,
    setDatabaseBannerUri
  ] = useState();

  const [fileBannerUrl, setFileBannerUrl] = useState();
  const [fileBanner, setFileBanner] = useState();
  // /banner useState

  const inputAddFileBannerRef = useRef();

  // avatar useState
  const [
    databaseHaveAvatar,
    setDatabaseHaveAvatar
  ] = useState(true);

  const [
    databaseAvatarUri,
    setDatabaseAvatarUri
  ] = useState();

  const [fileAvatarUrl, setFileAvatarUrl] = useState();
  const [fileAvatar, setFileAvatar] = useState();
  // /avatar useState

  const inputAddFileAvatarRef = useRef();

  const [userName, setUserName] = useState();
  const [userCustomId, setUserCustomId] = useState();
  const [userBio, setUserBio] = useState();

  const [
    creatorCrystalStatus,
    setCreatorCrystalStatus
  ] = useState();

  const [
    showBannerButtons,
    setShowBannerButtons
  ] = useState(false);

  const [
    showAvatarButtons,
    setShowAvatarButtons
  ] = useState(false);

  const saveBannerMutation = useMutation({
    mutationKey: ['saveBanner'],
    mutationFn: async () => {
      const file = fileBanner;
      const oldBannerUri = user?.data?.bannerUri || '';

      if (!databaseHaveBanner && !fileBanner) {
        await httpClient.patch(`/users/${userId}`, { bannerUri: '', oldBannerUri });
      } else if (file instanceof File) {
        const formData = new FormData();
        formData.append('image', file);
        const { imageUri } = await httpClient.post(`/users/${userId}/image`, formData);
        await httpClient.patch(`/users/${userId}`, { bannerUri: imageUri, oldBannerUri });
      }
    },
    onSuccess: () => {
      setFileBannerUrl(undefined);
      setFileBanner(undefined);
      if (inputAddFileBannerRef.current?.value) {
        inputAddFileBannerRef.current.value = '';
      }
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
    },
    onError: (error) => {
      console.warn('❌ Error uploading banner:', error);
      if (error?.error === 'File size exceeds 2.5 MB limit.') {
        alert(t('Common.LargeImageError'));
      } else {
        alert(t('Common.UploadingImageError'));
      }
    },
  });

  const onClickSaveBanner = () => {
    saveBannerMutation.mutate();
  };

  const onClickDeleteUserBanner = () => {
    setDatabaseHaveBanner(false);
    setDatabaseBannerUri(undefined);
    setFileBannerUrl(undefined);
    setFileBanner(null);
    inputAddFileBannerRef.current.value = '';
  };

  const saveAvatarMutation = useMutation({
    mutationKey: ['saveAvatar'],
    mutationFn: async () => {
      const file = fileAvatar;
      const oldAvatarUri = user?.data?.avatarUri || '';

      if (!databaseHaveAvatar && !fileAvatar) {
        await httpClient.patch(`/users/${userId}`, { avatarUri: '', oldAvatarUri });
      } else if (file instanceof File) {
        const formData = new FormData();
        formData.append('image', file);
        const { imageUri } = await httpClient.post(`/users/${userId}/image`, formData);
        await httpClient.patch(`/users/${userId}`, { avatarUri: imageUri, oldAvatarUri });
      }
    },

    onSuccess: () => {
      setFileAvatarUrl(undefined);
      setFileAvatar(undefined);
      if (inputAddFileAvatarRef.current?.value) {
        inputAddFileAvatarRef.current.value = '';
      }
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
    },
    onError: (error) => {
      console.warn('❌ Error uploading avatar:', error);
      if (error?.error === 'File size exceeds 2.5 MB limit.') {
        alert(t('Common.LargeImageError'));
      } else {
        alert(t('Common.UploadingImageError'));
      }
    },
  });

  const onClickSaveAvatar = () => {
    saveAvatarMutation.mutate();
  };

  const onClickDeleteUserAvatar = () => {
    setDatabaseHaveAvatar(false);
    setDatabaseAvatarUri(undefined);
    setFileAvatarUrl(undefined);
    setFileAvatar(null);
    inputAddFileAvatarRef.current.value = '';
  };

  useEffect(() => {
    if (user.isSuccess) {
      setDatabaseAvatarUri(user.data?.avatarUri ? (/^https?:\/\//.test(user.data.avatarUri) ? user.data.avatarUri : API_BASE_URL + user.data.avatarUri) : undefined);
      setDatabaseHaveAvatar(!!user.data?.avatarUri);
      setDatabaseBannerUri(user.data?.bannerUri ? (/^https?:\/\//.test(user.data.bannerUri) ? user.data.bannerUri : API_BASE_URL + user.data.bannerUri) : undefined);
      setDatabaseHaveBanner(!!user.data?.bannerUri);
      setUserName(user.data?.name);
      setUserCustomId(user.data?.customId);
      setUserBio(user.data?.profile?.bio);
      setCreatorCrystalStatus(user.data?.creator);
    }
  }, [user.data, user.status]);

  // convert avatar image
  const [
    avatarImageLoadingStatus,
    setAvatarImageLoadingStatus
  ] = useState(false);

  const [
    avatarImageLoadingStatusError,
    setAvatarImageLoadingStatusError
  ] = useState(false);

  useEffect(() => {
    if (avatarImageLoadingStatus === 100) {
      setTimeout(() => setAvatarImageLoadingStatus(false), 500);
    }
    if (avatarImageLoadingStatusError) {
      setTimeout(() => setAvatarImageLoadingStatusError(false), 3500);
    }
  }, [avatarImageLoadingStatus, avatarImageLoadingStatusError]);

  async function onChangeConvertAvatarImage(event) {
    setAvatarImageLoadingStatusError(false);
    setAvatarImageLoadingStatus(0);
    const imageFile = event.target.files[0];

    try {
      let webpFile;
      if (imageFile.type === 'image/gif') {
        for (let i = 0; i <= 100; i += 5) {
          await new Promise((res) => setTimeout(res, 10));
          setAvatarImageLoadingStatus(i);
        }
        webpFile = imageFile;
      } else {
        webpFile = await convertImage(imageFile, {
          newFileName: 'preview.webp',
          targetSizeBytes: 307200,
          fallbackQuality: 0.1,
          maxWidthOrHeight: 1920,
          onProgress: (progress) => setAvatarImageLoadingStatus(progress),
        });
      }
      setFileAvatar(webpFile);
      setFileAvatarUrl(URL.createObjectURL(webpFile));
      setTimeout(() => setAvatarImageLoadingStatus(false), 300);
      setAvatarImageLoadingStatusError(false);
    } catch (error) {
      console.log(error);
      setAvatarImageLoadingStatusError(true);
      setAvatarImageLoadingStatus(false);
    }
  }
  // /convert avatar image

  // convert banner image
  const [
    bannerImageLoadingStatus,
    setBannerImageLoadingStatus
  ] = useState(false);

  const [
    bannerImageLoadingStatusError,
    setBannerImageLoadingStatusError
  ] = useState(false);

  useEffect(() => {
    if (bannerImageLoadingStatus === 100) {
      setTimeout(() => setBannerImageLoadingStatus(false), 500);
    }
    if (bannerImageLoadingStatusError) {
      setTimeout(() => setBannerImageLoadingStatusError(false), 3500);
    }
  }, [
    bannerImageLoadingStatus,
    bannerImageLoadingStatusError
  ]);

  async function onChangeCompressedBannerImage(event) {
    setBannerImageLoadingStatusError(false);
    setBannerImageLoadingStatus(0);
    const imageFile = event.target.files[0];

    try {
      let webpFile;
      if (imageFile.type === 'image/gif') {
        for (let i = 0; i <= 100; i += 5) {
          await new Promise((res) => setTimeout(res, 10));
          setBannerImageLoadingStatus(i);
        }
        webpFile = imageFile;
      } else {
        webpFile = await convertImage(imageFile, {
          newFileName: 'preview.webp',
          targetSizeBytes: 307200,
          fallbackQuality: 0.1,
          maxWidthOrHeight: 1920,
          onProgress: (progress) => setBannerImageLoadingStatus(progress),
        });
      }
      setFileBanner(webpFile);
      setFileBannerUrl(URL.createObjectURL(webpFile));
      setTimeout(() => setBannerImageLoadingStatus(false), 300);
      setBannerImageLoadingStatusError(false);
    } catch (error) {
      console.log(error);
      setBannerImageLoadingStatusError(true);
      setBannerImageLoadingStatus(false);
    }
  }
  // /convert banner image

  // Restore the image and buttons to their original state when switching to another user's page

  useEffect(() => {

    // 1. Resetting the states of downloaded files
    setFileBanner(undefined);
    setFileBannerUrl(undefined);
    setFileAvatar(undefined);
    setFileAvatarUrl(undefined);

    // 2. Resetting progress bar states (if loading was in progress during the transition)
    setAvatarImageLoadingStatus(false);
    setAvatarImageLoadingStatusError(false);
    setBannerImageLoadingStatus(false);
    setBannerImageLoadingStatusError(false);

    // 3. Resetting the values in the inputs (so that you can select the same file again)
    if (inputAddFileBannerRef.current) {
      inputAddFileBannerRef.current.value = '';
    }
    if (inputAddFileAvatarRef.current) {
      inputAddFileAvatarRef.current.value = '';
    }

    // 4. Close the menus
    setShowBannerButtons(false);
    setShowAvatarButtons(false);

  }, [userId]);

  // /Restore the image and buttons to their original state when switching to another user's page

  const openMoreAboutUserModal = () => {
    dispatch(setUserId(userId));
    dispatch(setShowMoreAboutUserModal(true));
  };

  // const { isConnected, isPending, isError, isSuccess } = useWebSocket();

  const userOnline = user?.data?.status?.isOnline;

  const genderType = user?.data?.profile?.gender?.type || 'unspecified';

  // formatted last seen

  const [
    showFormattedLastSeen,
    setShowFormattedLastSeen
  ] = useState(false);

  const formattedLastSeen = useFormattedLastSeenDate(user?.data?.status?.lastSeen, genderType);

  const formattedLastSeenShort = useFormattedLastSeenDateShort(user.data?.status.lastSeen);

  // spawn timer for lastSeenShort
  const [
    isVisibleLastSeenShort,
    setIsVisibleLastSeenShort
  ] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => {
      setIsVisibleLastSeenShort(true);
    }, 500);

    return () => clearTimeout(timer);
  }, []);
  // /spawn timer for lastSeenShort

  // /formatted last seen

  // Logic to hide "Last seen" for very short durations
  // Determine the lines that need to be hidden (0-2 seconds, in Russian and English)
  const shortLastSeenExclusions = ['0 с', '1 с', '2 с', '0 s', '1 s', '2 s'];

  // Checking whether it is necessary to hide the short “was online”
  const shouldHideLastSeenShort = shortLastSeenExclusions.includes(formattedLastSeenShort);

  // Combined logic to display the short "was online"
  const shouldShowLastSeenShort = isVisibleLastSeenShort && user.data?.status.lastSeen && !shouldHideLastSeenShort;

  return (
    <>
      {(user.isPending || (logInStatus && isAuthPending)) && (
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}
      {user.isError && <NotFoundPage />}
      {user.isSuccess && (!logInStatus || isAuthSuccess) && (
        <div
          className={userHavePosts ? styles.user_information : styles.user_information_no_posts}
          data-user-information-dark-theme={darkThemeStatus}
        >
          <div
            className={styles.banner}
            onMouseOver={() => setShowBannerButtons(true)}
            onMouseOut={() => setShowBannerButtons(false)}
          >
            {(databaseHaveBanner || fileBannerUrl) && (
              fileBannerUrl ? (
                <img src={fileBannerUrl} alt="banner" />
              ) : databaseBannerUri?.endsWith('.gif') && logInStatus && (authorizedUser?.settings.interface.hideGif ?? false) ? (
                <div className={styles.word_gif_icon}>
                  <WordGifIcon />
                </div>
              ) : databaseBannerUri ? (
                <img src={databaseBannerUri} alt="banner" />
              ) : null
            )}
            {(authorizedUserAccessCheck && !saveBannerMutation.isPending) && (
              <div
                className={
                  showBannerButtons
                    ? `${styles.banner_buttons_wrap} ${styles.banner_buttons_wrap_show}`
                    : styles.banner_buttons_wrap
                }
              >
                <button className={styles.add_banner_button} onClick={() => inputAddFileBannerRef.current.click()}>
                  <CameraIcon />
                </button>
                {(fileBanner instanceof File || (fileBanner === null && !databaseHaveBanner)) && (
                  <button className={styles.save_banner_button} onClick={onClickSaveBanner}>
                    <AcceptIcon />
                  </button>
                )}
                <input
                  ref={inputAddFileBannerRef}
                  type="file"
                  accept="image/*"
                  onChange={(event) => onChangeCompressedBannerImage(event)}
                  hidden
                />
                {(databaseHaveBanner || fileBanner) && (
                  <button className={styles.delete_banner_button} onClick={onClickDeleteUserBanner}>
                    <DeleteIcon />
                  </button>
                )}
              </div>
            )}
            {saveBannerMutation.isPending && (
              <div className={styles.banner_save_loader}>
                <Loader />
              </div>
            )}
          </div>
          <div className={styles.user_options}>
            <button
              onClick={() =>
                logInStatus
                  ? buttonShowMenuPostOptions(!showMenuUserOptions)
                  : dispatch(setShowAccessModal(true))
              }
            >
              <ThreeDotsIcon />
            </button>
            {showMenuUserOptions && (
              <nav
                ref={menuUserOptions}
                className={
                  menuUserOptionsFadeOut
                    ? `${styles.user_options_menu} ${styles.user_options_menu_fade_out}`
                    : styles.user_options_menu
                }
                onAnimationEnd={(e) => {
                  if (e.animationName === styles.fadeOut) {
                    setShowMenuUserOptions(false);
                    setMenuUserOptionsFadeOut(false);
                  }
                }}
              >
                <ul>
                  {authorizedUserAccessCheck && (
                    <li>
                      <Link to={`/users/${userId}/edit`}>{t('UserInformation.EditUser')}</Link>
                    </li>
                  )}
                </ul>
              </nav>
            )}
          </div>
          {bannerImageLoadingStatus ? (
            <div className={styles.banner_image_loading_bar_wrap}>
              <LoadingBar value={bannerImageLoadingStatus} />
            </div>
          ) : null}
          {bannerImageLoadingStatusError && (
            <div className={styles.banner_image_loading_error}>
              <p>{t('SystemMessages.Error')}</p>
            </div>
          )}
          <div
            className={
              !userName && !userBio
                ? `${styles.avatar_name_wrap} ${styles.avatar_name_wrap_without_name_without_about}`
                : styles.avatar_name_wrap
            }
          >
            <div
              className={!userBio ? `${styles.avatar_name} ${styles.avatar_name_without_about}` : styles.avatar_name}
            >
              <div className={styles.avatar_wrap}>
                <div
                  className={userName ? styles.avatar : `${styles.avatar} ${styles.avatar_without_name}`}
                  onMouseOver={(event) => {
                    event.stopPropagation();
                    setShowAvatarButtons(true);
                  }}
                  onMouseOut={(event) => {
                    event.stopPropagation();
                    setShowAvatarButtons(false);
                  }}
                >
                  {(databaseHaveAvatar || fileAvatarUrl) ? (
                    fileAvatarUrl ? (
                      <img src={fileAvatarUrl} alt="avatar" />
                    ) : databaseAvatarUri?.endsWith('.gif') && logInStatus && (authorizedUser?.settings.interface.hideGif ?? false) ? (
                      <div className={styles.gif_circle_icon}>
                        <GifInCircleIcon />
                      </div>
                    ) : databaseAvatarUri ? (
                      <img src={databaseAvatarUri} alt="avatar" />
                    ) : null
                  ) : (
                    <div className={styles.no_avatar_icon}>
                      <NoAvatarIcon />
                    </div>
                  )}
                  {(authorizedUserAccessCheck && !saveAvatarMutation.isPending) && (
                    <div
                      className={
                        showAvatarButtons
                          ? `${styles.avatar_buttons_wrap} ${styles.avatar_buttons_wrap_show}`
                          : styles.avatar_buttons_wrap
                      }
                    >
                      <div
                        className={styles.avatar_buttons}
                      >
                        <button
                          className={styles.add_avatar_button}
                          onClick={() => inputAddFileAvatarRef.current.click()}
                        >
                          <CameraIcon />
                        </button>
                        {(fileAvatar instanceof File || (fileAvatar === null && !databaseHaveAvatar)) && (
                          <button className={styles.save_avatar_button} onClick={onClickSaveAvatar}>
                            <AcceptIcon />
                          </button>
                        )}
                        <input
                          ref={inputAddFileAvatarRef}
                          type="file"
                          accept="image/*"
                          onChange={(event) => onChangeConvertAvatarImage(event)}
                          hidden
                        />
                        {(databaseHaveAvatar || fileAvatar) && (
                          <button className={styles.delete_avatar_button} onClick={onClickDeleteUserAvatar}>
                            <DeleteIcon />
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                  {avatarImageLoadingStatus ? (
                    <div className={styles.avatar_image_loading_bar_wrap}>
                      <LoadingBar value={avatarImageLoadingStatus} />
                    </div>
                  ) : null}
                  {avatarImageLoadingStatusError && (
                    <div className={styles.avatar_image_loading_error}>
                      <p>{t('SystemMessages.Error')}</p>
                    </div>
                  )}

                  {(userOnline) ? (
                    <div className={styles.user_online_status_circle_icon}>
                      <UserOnlineStatusCircleIcon />
                    </div>
                  ) : (

                    //initially - isVisibleLastSeenShort &&
                    (shouldShowLastSeenShort) && (
                      <div className={styles.last_seen_short_icon}
                        onMouseOver={(event) => {
                          event.stopPropagation();
                          setShowFormattedLastSeen(true);
                        }}
                        onMouseOut={(event) => {
                          event.stopPropagation();
                          setShowFormattedLastSeen(false);
                        }}
                      >
                        <p>{formattedLastSeenShort}</p>
                      </div>
                    )
                  )}

                  {showFormattedLastSeen && (
                    <div className={styles.last_seen_wrap}>
                      <p>{formattedLastSeen}</p>
                    </div>
                  )}
                </div>
                {saveAvatarMutation.isPending && (
                  <div className={styles.avatar_save_loader}>
                    <Loader />
                  </div>
                )}
              </div>
              <div className={styles.name_id_wrap}>
                {userName && (
                  <div className={styles.name}>
                    <p>{userName}</p>
                    {creatorCrystalStatus && (
                      <div className={styles.crystal_icon}>
                        <CrystalIcon />
                      </div>
                    )}
                  </div>
                )}
                {userCustomId && (
                  <div className={styles.id}>
                    <p>@{userCustomId}</p>
                  </div>
                )}
              </div>
            </div>
          </div>
          {logInStatus && authorizedUser?.customId !== userId && user.data?._id && (
            <ProfileActions profileCustomId={userId} profileUserId={user.data._id} />
          )}
          {userBio && (
            <div className={styles.about_wrap}>
              <div className={userName ? styles.about : styles.about_without_name}>
                <p>{formatLinksInText(userBio)}</p>
              </div>
            </div>
          )}
          {/* additional information */}
          <div className={
            userName ?
              styles.additional_information_wrap
              :
              `${styles.additional_information_wrap} ${styles.additional_information_wrap_no_name}`
          }>
            <div className={styles.additional_information_wrap_button}>
              <button onClick={openMoreAboutUserModal}>
                {t("UserInformation.ShowMore")}
              </button>
            </div>
          </div>
          {/* /additional information */}
        </div >
      )
      }
    </>
  );
}
