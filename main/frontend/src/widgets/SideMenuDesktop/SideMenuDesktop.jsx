import { useSelector } from 'react-redux';
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";

import { useAuthData } from "../../features";
import {
  UserIcon,
  SettingsIcon,
  MessagesIcon,
  FriendsIcon,
  GroupsIcon,
  PhotosIcon,
  VideosIcon,
  BookmarkIcon,
  HelpIcon,
  CrystalIcon,
  LikeIcon,
  DocumentationIcon,
} from '../../shared/ui';

import styles from "./SideMenuDesktop.module.css";

export function SideMenuDesktop() {

  const { authorizedUser } = useAuthData();
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);
  const { t } = useTranslation();

  if (!authorizedUser) {
    return null
  }

  return (
    <nav
      className={styles.side_menu_desktop}
      data-side-menu-desktop-dark-theme={darkThemeStatus}
    >
      <ul>
        <li className={styles.user}>
          <UserIcon />
          <p>{t("SideMenuDesktop.MyProfile")}</p>
          <Link to={"/" + authorizedUser.customId}></Link>
        </li>
        
        {/* --- FIXED: Messages Link --- */}
        <li className={styles.messages}>
          <MessagesIcon />
          <p>{t("SideMenuDesktop.Messages")}</p>
          <Link to="/messages"></Link> 
        </li>
        {/* --------------------------- */}

        <li className={styles.friends}>
          <FriendsIcon />
          <p>{t("SideMenuDesktop.Friends")}</p>
          <Link to="/friends"></Link>
        </li>
        <li className={styles.groups}>
          <GroupsIcon />
          <p>{t("SideMenuDesktop.Communities")}</p>
          <Link to="/communities"></Link>
        </li>
        <li className={styles.games}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <rect x="2" y="7" width="20" height="11" rx="5.5" />
            <line x1="7" y1="11" x2="7" y2="14" />
            <line x1="5.5" y1="12.5" x2="8.5" y2="12.5" />
            <circle cx="16" cy="11.5" r="1.1" />
            <circle cx="18.5" cy="14" r="1.1" />
          </svg>
          <p>{t("SideMenuDesktop.Games")}</p>
          <Link to="/games"></Link>
        </li>
        <li className={styles.forums}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <path d="M4 5.5h16a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5H9l-4 3.5V16.5H4A1.5 1.5 0 0 1 2.5 15V7A1.5 1.5 0 0 1 4 5.5Z" />
            <line x1="6.5" y1="9.5" x2="17.5" y2="9.5" />
            <line x1="6.5" y1="12.5" x2="13.5" y2="12.5" />
          </svg>
          <p>{t("SideMenuDesktop.Forums")}</p>
          <Link to="/forums"></Link>
        </li>
        <li className={styles.photo}>
          <PhotosIcon />
          <p>{t("SideMenuDesktop.Photo")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.video}>
          <VideosIcon />
          <p>{t("SideMenuDesktop.Video")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.bookmark}>
          <BookmarkIcon />
          <p>{t("SideMenuDesktop.Bookmarks")}</p>
          <Link to={`/${authorizedUser.customId}`}></Link>
        </li>
        <li className={styles.like}>
          <LikeIcon />
          <p>{t("SideMenuDesktop.Likes")}</p>
          <Link to={"/likes/" + authorizedUser.customId}></Link>
        </li>
        <li className={styles.settings}>
          <SettingsIcon />
          <p>{t("SideMenuDesktop.Settings")}</p>
          <Link to={`/users/${authorizedUser.customId}/edit`}></Link>
        </li>
        <li className={styles.crystal}>
          <CrystalIcon />
          <p>{t("SideMenuDesktop.AboutCrystal")}</p>
          <Link to={"/about-crystal"} target="_blank"></Link>
        </li>
        <li className={styles.agreements}>
          <DocumentationIcon />
          <p>{t("SideMenuDesktop.Agreements")}</p>
          <Link to={"/agreements"} target="_blank"></Link>
        </li>
        <li className={styles.help}>
          <HelpIcon />
          <p>{t("SideMenuDesktop.Help")}</p>
          <Link to={"/help"} target="_blank"></Link>
        </li>
      </ul>
    </nav>
  );
}
