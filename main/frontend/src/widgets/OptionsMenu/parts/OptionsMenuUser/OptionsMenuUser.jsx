import {
  useRef,
  useState,
  useEffect,
} from "react";
import {
  useDispatch,
  useSelector
} from "react-redux";
import { Link } from "react-router-dom";
import {
  useMutation,
  useQueryClient,
} from "@tanstack/react-query";
import { useTranslation } from "react-i18next";

import { httpClient } from "../../../../shared/api";
import { API_BASE_URL } from "../../../../shared/constants";
import { useAuthData } from "../../../../features";
import { setlogInStatus } from "../../../../features/auth/logInStatusSlice";
import { useUserStatus } from '../../../../shared/hooks';
import { ThemeSwitcher } from "../../../../features/theme/ThemeSwitcher";
import {
  setShowSideMenuMobile,
  setSideMenuMobileFadeOut,
  setShowSideMenuMobileBackground
} from "../../../../features/sideMenuMobile/sideMenuMobileSlice";
import {
  setShowMobileSearchAndSort
} from "../../../../features/showMobileSearchAndSort/showMobileSearchAndSortSlice";
import {
  PlusIcon,
  UserIcon,
  SearchIcon,
  CrystalIcon,
  DotsMenuIcon,
  NoAvatarIcon,
  MessagesIcon,
  LanguageIcon,
  SettingsIcon,
  GifInCircleIcon,
  AuthorizationIcon,
  NotificationsIcon,
  UserOnlineStatusCircleIcon
} from "../../../../shared/ui";

import styles from "./OptionsMenuUser.module.css";

export function OptionsMenuUser() {

  const queryClient = useQueryClient();

  // authorized user
  const { authorizedUser, isPending } = useAuthData();
  // /authorized user

  const { userOnline } = useUserStatus(authorizedUser?.customId, { delay: 100 });

  // const userOnline = authorizedUser?.status?.isOnline;

  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const dispatch = useDispatch();

  const { showSideMenuMobile } = useSelector(
    (state) => state.sideMenuMobile
  );

  const { showMobileSearchAndSort } = useSelector(
    (state) => state.showMobileSearchAndSort
  );

  const { t, i18n } = useTranslation();
  const changeLanguage = (lng) => {
    i18n.changeLanguage(lng);
  };
  const [lang, setlang] = useState();

  useEffect(() => {
    switch (
    i18n.language.length > 3 ? i18n.language.slice(0, -3) : i18n.language
    ) {
      case "en":
        setlang("ru");
        break;
      case "ru":
        setlang("en");
        break;
      default:
        setlang("ru");
    }
  }, [i18n.language]);

  const changeLang = () => {
    setlang((state) => (state === "en" ? "ru" : "en"));
    changeLanguage(lang);
  };

  const userMenuListRef = useRef();

  const [
    showSearchIcon,
    setShowSearchIcon
  ] = useState(false);

  const [
    fadeOutUserMenuList,
    setFadeOutUserMenuList
  ] = useState(false);

  const [
    showUserMenuList,
    setShowUserMenuList
  ] = useState(false);

  const onClickShowUserMenuList = (open) => {
    if (open) {
      setShowUserMenuList(true);
    } else {
      setFadeOutUserMenuList(true);
    }
  };

  // log out
  const onClickLogout = async () => {
    if (window.confirm(t("OptionsMenuUser.LogOut"))) {
      logOut.mutate();
    };
  };

  const logOut = useMutation({
    mutationKey: ['logOut'],
    mutationFn: () => {
      return httpClient.post("/auth/logout");
    },

    onSuccess: () => {
      dispatch(setlogInStatus(false));
      window.localStorage.removeItem('logIn');
      setFadeOutUserMenuList(false);
      setShowUserMenuList(false);
      queryClient.removeQueries({ queryKey: ['users'] });
      queryClient.removeQueries({ queryKey: ['posts'] });
    },

    onError: (error) => {
      console.log(error);
    },

  });
  // /log out

  // closing a menu when clicking outside its field
  useEffect(() => {
    if (userMenuListRef.current) {
      const handler = (e) => {
        if (!userMenuListRef.current.contains(e.target)) {
          setFadeOutUserMenuList(true);
        }
      };
      document.addEventListener("mousedown", handler);
      return () => {
        document.removeEventListener("mousedown", handler);
      };
    }
  });
  // /closing a menu when clicking outside its field

  useEffect(() => {
    window.addEventListener("scroll", () => {
      if (window.scrollY > 20) {
        setShowSearchIcon(true);
      } else {
        setShowSearchIcon(false);
      }
    });
  }, []);

  const onClickShowSideMenuMobile = () => {
    if (showSideMenuMobile) {
      dispatch(setSideMenuMobileFadeOut(true));
    } else {
      dispatch(setShowSideMenuMobile(true));
      dispatch(setShowSideMenuMobileBackground(true));
    }
    dispatch(
      setShowMobileSearchAndSort(false)
    );
  };

  const onClickShowMobileSearchAndSort = () => {
    dispatch(
      setShowMobileSearchAndSort(!showMobileSearchAndSort)
    );
  };

  if (isPending) {
    return null
  }

  return (
    <div
      className={styles.options_menu_user} data-options-menu-user-dark-theme={darkThemeStatus}>
      <button
        className={styles.notifications}>
        <NotificationsIcon />
      </button>
      <div className={styles.theme_switcher}>
        <ThemeSwitcher />
      </div>
      <button
        className={
          showSearchIcon
            ? styles.search_icon
            : styles.search_icon + " " + styles.search_icon_hide
        }
        onClick={() => onClickShowMobileSearchAndSort()}
      >
        <SearchIcon />
      </button>
      <button className={styles.messages}>
        <MessagesIcon />
      </button>
      <button
        className={styles.side_menu_mobile}
        onClick={() => onClickShowSideMenuMobile()}
      >
        <DotsMenuIcon />
      </button>
      <button className={styles.add_post}>
        <PlusIcon />
        <Link to="/posts/new"></Link>
      </button>
      <button className={styles.user_menu}
        onClick={() => onClickShowUserMenuList(!showUserMenuList)}
      >
        {authorizedUser?.avatarUri ? (
          <div className={styles.avatar}>
            {authorizedUser?.avatarUri.endsWith('.gif') && authorizedUser?.settings.interface.hideGif ? (
              <div className={styles.gif_circle_icon}>
                <GifInCircleIcon />
              </div>
            ) : (
              <img src={(/^https?:\/\//.test(authorizedUser?.avatarUri) ? authorizedUser?.avatarUri : API_BASE_URL + authorizedUser?.avatarUri)} alt="user avatar" />
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
      </button>
      {showUserMenuList && (
        <div
          ref={userMenuListRef}
          className={
            fadeOutUserMenuList
              ? `${styles.user_menu_list} ${styles.user_menu_list_fade_out}`
              : `${styles.user_menu_list}`
          }
          onAnimationEnd={(e) => {
            if (e.animationName === styles.fadeOut) {
              setShowUserMenuList(false);
              setFadeOutUserMenuList(false);
            }
          }}
        >
          <div
            onClick={() => setFadeOutUserMenuList(true)}
            className={styles.user_menu_list_user_name_user_custom_id_wrap}
          >
            {authorizedUser.name && (
              <div className={styles.user_menu_list_user_name}>
                <p>{authorizedUser.name}</p>
                {authorizedUser.creator && <CrystalIcon />}
              </div>
            )
            }
            <div className={styles.user_menu_list_user_custom_id}>
              <p>@{authorizedUser.customId}</p>
            </div>
            <Link to={`/${authorizedUser.customId}`}></Link>
          </div>
          <nav>
            <ul>
              <li
                onClick={() => setFadeOutUserMenuList(true)}
                className={styles.user_menu_list_my_profile}
                ref={userMenuListRef}
              >
                <UserIcon />
                {t("OptionsMenuUser.MyProfile")}
                <Link to={`/${authorizedUser.customId}`}></Link>
              </li>
              <li
                onClick={() => setFadeOutUserMenuList(true)}
                className={styles.user_menu_list_settings}
                ref={userMenuListRef}
              >
                <SettingsIcon />
                {t("OptionsMenuUser.Settings")}
                <Link to={`/users/${authorizedUser.customId}/edit`}></Link>
              </li>
              <li className={styles.user_menu_list_item_lang} onClick={() => changeLang()}>
                <LanguageIcon />
                {lang === "en" ? <span>English</span> : <span>Русский</span>}
              </li>
              <li
                className={styles.user_menu_list_exit}
                onClick={onClickLogout}
              >
                <AuthorizationIcon />
                {t("OptionsMenuUser.Exit")}
              </li>
            </ul>
            <div className={styles.user_menu_list_theme_switcher}>
              <ThemeSwitcher />
            </div>
          </nav>
        </div>
      )}
    </div>
  );
}
