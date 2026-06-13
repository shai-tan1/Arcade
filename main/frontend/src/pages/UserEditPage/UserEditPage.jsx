import {
  useRef,
  useState,
  useEffect
} from 'react';
import {
  useDispatch,
  useSelector
} from 'react-redux';
import {
  Link,
  Navigate,
  useParams,
  useNavigate,
} from 'react-router-dom';
import {
  useQuery,
  useMutation,
  useQueryClient,
} from '@tanstack/react-query';
import TextareaAutosize from 'react-textarea-autosize';
import { useTranslation } from 'react-i18next';

import { httpClient } from '../../shared/api';
import { API_BASE_URL } from '../../shared/constants';
import { useAuthData } from "../../features";
import { setlogInStatus } from '../../features/auth/logInStatusSlice';
import { NotFoundPage } from '../../pages';
import {
  Loader,
  CrystalIcon,
  NoAvatarIcon,
  GifInCircleIcon,
  EyeIconSecondVersionIcon,
  ClosedEyeSecondVersionIcon,
  UserOnlineStatusCircleIcon
} from '../../shared/ui';

import styles from "./UserEditPage.module.css";

export function UserEditPage() {

  // authorized user
  const { authorizedUser } = useAuthData();
  // /authorized user

  const [
    serverMessage,
    setServerMessage
  ] = useState();

  const darkThemeStatus = useSelector(
    (state) => state.darkThemeStatus
  );

  const dispatch = useDispatch();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { userId } = useParams();
  const linkToUserProfile = window.location.origin + "/" + userId;

  //userName
  const userNameRef = useRef();
  const [userName, setUserName] = useState();

  const [
    userNameValueDatabase,
    setUserNameValueDatabase
  ] = useState();

  const [
    characterCounterUsername,
    setCharacterCounterUsername
  ] = useState();

  const onChangeUserName = (event) => {
    setCharacterCounterUsername(
      event.target.value.length
    );
    setUserName(event.target.value);
  };
  // /userName

  // userId
  const userIdRef = useRef();
  const [userIdValue, setUserIdValue] = useState();

  const [
    userIdValueDatabase,
    setUserIdValueDatabase
  ] = useState();

  const [
    characterCounterUserId,
    setCharacterCounterUserId
  ] = useState("");

  const onChangeUserId = (e) => {
    setUserIdValue(e.target.value);
    setCharacterCounterUserId(
      e.target.value.length
    );
    setServerMessage(e.target.value);
  };
  const [
    validationUserIdErrorStatus, setValidationUserIdErrorStatus
  ] = useState();
  // /userId

  const [
    serverPostsDeletedMessage,
    setServerPostsDeletedMessage
  ] = useState();

  useEffect(() => {
    if (serverPostsDeletedMessage || serverMessage) {
      setTimeout(() => {
        setServerPostsDeletedMessage(false);
        setServerMessage(false);
      }, "11500");
    }
  }, [serverPostsDeletedMessage, serverMessage]);

  // user bio
  const userBioRef = useRef();
  const [userBio, setUserBio] = useState();

  const [
    userBioValueDatabase,
    setUserBioValueDatabase
  ] = useState();

  const [
    characterCounterUserBio,
    setCharacterCounterUserBio
  ] = useState();

  const onChangeUserBio = (e) => {
    setCharacterCounterUserBio(
      e.target.value.length
    );
    setUserBio(e.target.value);
  };
  // /user bio

  const [userData, setUserData] = useState(false);

  const user = useQuery({
    queryKey: ['users', "editUserPageUser", userId],
    refetchOnWindowFocus: false,
    retry: false,
    queryFn: () =>
      httpClient
        .get(`/users/${userId}/edit`)
        .then((response) => {
          return response;
        }),
  });

  const userOnline = user?.data?.status?.isOnline;

  useEffect(() => {
    user.isError && setServerMessage(user.error.message);
    setUserData(user.data);
  }, [user]);

  // checking whether the user has posts

  const [
    userHavePosts,
    setUserHavePost
  ] = useState(false);

  const userPosts = useQuery({
    queryKey: ['posts', "editUserPageUserHavePosts", userId],
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () =>
      httpClient
        .get(`/posts/user/${userId}`)
        .then((response) => {
          return response;
        }),
  });

  useEffect(() => {
    userPosts.data?.posts
      .length > 0
      ? setUserHavePost(true)
      : setUserHavePost(false);
  }, [userPosts]);
  // /checking whether the user has posts

  const [
    userCreatorStatus,
    setUserCreatorStatus
  ] = useState();

  useEffect(() => {
    setUserName(userData?.name);
    setUserNameValueDatabase(userData?.name);
    setUserIdValue(userData?.customId);
    setUserIdValueDatabase(userData?.customId);
    setUserBio(userData?.profile?.bio);
    setUserBioValueDatabase(userData?.profile?.bio);
    setUserCreatorStatus(userData?.creator);
  }, [userData]);

  // user authorization check
  const userAuthorizationCheck =
    (authorizedUser?.creator && userId) !== authorizedUser?.customId;
  const userAuthorizationCheckToChangePassword =
    authorizedUser?.customId === userId;
  // /user authorization check

  const { t } = useTranslation();
  const checkingUserChanges =
    userNameValueDatabase !== userName ||
    userIdValueDatabase !== userIdValue ||
    userBioValueDatabase !== userBio;

  const saveUserChanges = useMutation({
    mutationKey: ['saveUserChanges'],
    mutationFn: (fields) => {
      return httpClient.patch(`/users/${userId}`, fields);
    },

    onSuccess: () => {
      navigate(`/users/${userIdValue}/edit`);
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
    },

    onError: (error) => {
      setServerMessage(error.message);
    },

  });

  const onClickSaveUserChanges = async () => {
    const fields = {
      userId: userId,
      name: userName,
      customId: userIdValue,
      bio: userBio,
    };
    if (window.confirm(t("UserEditPage.SaveChanges"))) {
      saveUserChanges.mutate(fields);
    }
  };

  // hideGif
  const hideGif = useMutation({
    mutationKey: ['hideGif'],
    mutationFn: (hideGif) => {
      return httpClient.patch(`/users/${userId}/settings`, { hideGif });
    },

    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['me'] });
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
    },

    onError: (error) => {
      setServerMessage(error.message);
    },
  });

  const onClickHideGif = () => {
    const newHideGifValue = !authorizedUser?.settings.interface.hideGif;
    hideGif.mutate(newHideGifValue);
  };
  // /hideGif

  // change password

  const [
    changePasswordFormStatus,
    setChangePasswordFormStatus
  ] = useState(false);

  const [
    characterCounterNewPassword,
    setCharacterCounterNewPassword
  ] = useState();

  // old password
  const oldPasswordInputRef = useRef();

  const [
    showOldPassword,
    setShowOldPassword
  ] = useState(false);

  const [oldPassword, setOldPassword] = useState();

  const onChangeOldPassword = (e) => {
    setOldPassword(e.target.value);
    setServerMessage(e.target.value);
  };
  // /old password

  // new password
  const newPasswordInputRef = useRef();

  const [
    showNewPassword,
    setShowNewPassword
  ] = useState(false);

  const [newPassword, setNewPassword] = useState();

  const [
    validatingNewPassword,
    setValidatingNewPassword
  ] = useState();

  const newPasswordValidationRule = /^[a-zA-Z\d!@#$%^&*[\]{}()?"\\/,><':;|_~`=+-]{8,35}$/;
  const onChangeNewPassword = (e) => {
    setServerMessage(e.target.value);
    setNewPassword(e.target.value);
    e.target.value?.match(newPasswordValidationRule) ? setValidatingNewPassword(true) : setValidatingNewPassword(false);
    setCharacterCounterNewPassword(
      e.target.value.length
    );
  };
  // /new password

  const changePassword = useMutation({
    mutationKey: ['changePassword'],
    mutationFn: (fields) => {
      return httpClient.post(`/users/${userId}/password/`, fields);
    },
    onSuccess: (data) => {
      setServerMessage(data.message);
      setNewPassword('');
      setOldPassword('');
      setValidatingNewPassword(false);
      newPasswordInputRef.current.value = '';
      oldPasswordInputRef.current.value = '';
      setCharacterCounterNewPassword(null)
    },
    onError: (error) => {
      setServerMessage(error.message);
    },
  });

  const onClickChangePassword = async () => {
    const fields = {
      oldPassword: oldPassword,
      newPassword: newPassword,
    };
    if (window.confirm(t("UserEditPage.SaveChanges"))) {
      changePassword.mutate(fields);
    }
  };
  // /change password

  const onClickDeleteAllPostsByUser = async (event) => {
    event.preventDefault();
    if (
      window.confirm(
        userAuthorizationCheck
          ? t("UserEditPage.DeleteAllPostsByUser")
          : t("UserEditPage.DeleteAllYourPosts"),
      )
    ) {
      deleteAllPostsByUserMutation.mutate();
    }
  };

  const deleteAllPostsByUserMutation = useMutation({
    mutationKey: ['deleteAllPostsByUser'],
    mutationFn: () => {

      return httpClient
        .delete(`/posts/user/${userId}`);
    },

    onSuccess: (response) => {
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      setServerPostsDeletedMessage(response.message);
      setUserHavePost(false);
    },

    onError: (error) => {
      console.log(error);
    },

  });
  // /delete all posts by user

  // delete user account
  const onClickDeleteUserAccount = async () => {
    if (window.confirm(t("UserEditPage.DeleteAccountQuestion"))) {
      deleteUserAccountMutation.mutate();
    }
  };

  const deleteUserAccountMutation = useMutation({
    mutationKey: ['deleteUserAccount'],
    mutationFn: () => {

      return httpClient
        .delete(`/users/${userId}`);
    },

    onSuccess: () => {

      navigate("/");
      if (authorizedUser?.customId === userId) {
        dispatch(setlogInStatus(false));
        window.localStorage.removeItem('logIn');
        queryClient.invalidateQueries({ queryKey: ['posts'] });
        queryClient.invalidateQueries({ queryKey: ['users'] });
        httpClient.post("/auth/logout");
      }
      else {
        queryClient.invalidateQueries({ queryKey: ['posts'] });
        queryClient.invalidateQueries({ queryKey: ['users'] });
        queryClient.invalidateQueries({ queryKey: ['me'] });
      }
    },

    onError: (error) => {
      console.log(error);
    },

  });
  // /delete user account

  useEffect(() => {
    if (userNameValueDatabase === userName) {
      setCharacterCounterUsername(null);
    }
    if (userIdValueDatabase === userIdValue) {
      setCharacterCounterUserId(null);
    }
    if (userBioValueDatabase === userBio) {
      setCharacterCounterUserBio(null);
    }
    setValidationUserIdErrorStatus(
      userIdValue === undefined
        ? false
        : !/^[a-zA-Z0-9-_]{1,35}$/.test(userIdValue),
    );
  }, [
    userNameValueDatabase,
    userName,
    userIdValueDatabase,
    userIdValue,
    userBioValueDatabase,
    userBio,
  ]);

  // Conditions for gender
  const [
    changeGenderFormStatus,
    setChangeGenderFormStatus
  ] = useState(false);
  const [customGender, setCustomGender] = useState('');

  // Mutation for sex preservation
  const saveGender = useMutation({
    mutationKey: ['saveGender'],
    mutationFn: (fields) => {
      return httpClient.patch(`/users/${userIdValue}`, fields);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
      setServerMessage(null)
    },
    onError: (error) => {
      setServerMessage(error.message);
    },
  });

  // Floor treatments
  const onClickGender = (genderType) => {
    const fields = { gender: { type: genderType } }; // Without customValue
    saveGender.mutate(fields); // We send it directly to the database
    // setChangeGenderFormStatus(false); // Close the menu
    setCustomGender('');
  };

  const onClickCustomGender = () => {
    setChangeGenderFormStatus(!changeGenderFormStatus);
    setCustomGender(''); // Clearing the field when opening/closing
  };

  const onSubmitCustomGender = () => {
    if (customGender.trim().length > 0 && customGender.length <= 50) {
      const fields = { gender: { type: 'custom', customValue: customGender } };
      saveGender.mutate(fields); // We send it directly to the database
      // setChangeGenderFormStatus(false); // Close the form
      setCustomGender(''); // Clearing the field
    }
  };

  const onChangeCustomGender = (e) => {
    setCustomGender(e.target.value);
  };

  // Function for generating button text
  const getGenderButtonText = () => {
    if (changeGenderFormStatus) {
      return t("UserEditPage.Hide"); //If the menu is open, show "Hide"
    }

    const genderType = authorizedUser?.profile?.gender?.type || 'unspecified';
    const translations = {
      male: t("UserEditPage.Male"),
      female: t("UserEditPage.Female"),
      unspecified: t("UserEditPage.Unspecified"),
      custom: authorizedUser?.profile?.gender?.customValue || t("UserEditPage.Unspecified"),
    };

    return (
      <>
        <strong>{t("UserEditPage.Gender")}:</strong> {translations[genderType]}
      </>
    );;
  };

  // Handler for hiding/showing the floor
  const onClickHideGender = () => {
    const newHideGenderValue = !authorizedUser?.settings.privacy.hideGender;
    hideGender.mutate(newHideGenderValue);
  };

  // Mutation for concealment/display of gender
  const hideGender = useMutation({
    mutationKey: ['hideGender'],
    mutationFn: (hideGender) => {
      return httpClient.patch(`/users/${userIdValue}/settings`, { hideGender });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['me'] });
      queryClient.invalidateQueries({ queryKey: ['users'] });
    },
    onError: (error) => {
      setServerMessage(error.message);
    },
  });

  const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1);

  if (serverMessage === "No access") {
    return <Navigate to="/" />;
  }

  return (
    <>
      {user.isPending &&
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      }

      {user.isError && <NotFoundPage />}

      {user.isSuccess && (
        <div
          className={styles.edit_user}
          data-edit-user-page-dark-theme={darkThemeStatus}
        >
          <div className={styles.title}>
            <h1>{t("UserEditPage.EditUser")}</h1>
          </div>
          <div className={styles.user_info_wrap}>
            <div className={styles.user_info}>
              <Link to={linkToUserProfile}></Link>
              {user.data?.avatarUri ? (
                <div className={styles.avatar}>
                  {user.data?.avatarUri?.endsWith('.gif') && authorizedUser?.settings.interface.hideGif ? (
                    <div className={styles.gif_circle_icon}>
                      <GifInCircleIcon />
                    </div>
                  ) : (
                    <img src={(/^https?:\/\//.test(user.data?.avatarUri) ? user.data?.avatarUri : API_BASE_URL + user.data?.avatarUri)} alt="user avatar" />
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
              <div className={styles.user_info_user_name_custom_id_wrap}>
                <div className={styles.user_info_user_name_wrap}>
                  <div className={styles.user_info_user_name}>
                    <p>{userName}</p>
                  </div>
                  {userCreatorStatus && (
                    <div className={styles.crystal_icon}>
                      <CrystalIcon />
                    </div>
                  )}
                </div>
                <div className={styles.user_info_custom_id}>
                  <p>@{userIdValue}</p>
                </div>
              </div>
            </div>
          </div>
          <div className={styles.user_name}>
            <TextareaAutosize
              type="text"
              maxLength={200}
              ref={userNameRef}
              value={userName}
              variant="standard"
              placeholder={t("UserEditPage.UserName")}
              onChange={onChangeUserName}
            />
          </div>
          {characterCounterUsername > 0 && (
            <div className={styles.letter_counter}>
              <p>{characterCounterUsername}/200</p>
            </div>
          )}
          <div className={styles.user_id}>
            <TextareaAutosize
              type="text"
              maxLength={35}
              ref={userIdRef}
              value={userIdValue}
              variant="standard"
              placeholder="Id"
              onChange={onChangeUserId}
            />
            {characterCounterUserId > 0 && (
              <div className={styles.letter_counter}>
                <p>{characterCounterUserId}/35</p>
              </div>
            )}
          </div>
          {validationUserIdErrorStatus && (
            <div className={styles.user_id_validation_error}>
              <p>
                {t(
                  "UserEditPage.IdErrorMinimumMaximumLengthSymbols",
                )}
              </p>
            </div>
          )}
          {serverMessage === "This Id already exists" && (
            <div className={styles.user_id_server_error}>
              <p>
                {t("UserEditPage.IdAlreadyExists")}
              </p>
            </div>
          )}
          <div className={styles.user_about_me}>
            <TextareaAutosize
              type="text"
              maxLength={175}
              ref={userBioRef}
              value={userBio}
              variant="standard"
              placeholder={t("UserEditPage.UserBio")}
              onChange={onChangeUserBio}
            />
          </div>
          {characterCounterUserBio > 0 && (
            <div className={styles.letter_counter}>
              <p>{characterCounterUserBio}/175</p>
            </div>
          )}
          {(checkingUserChanges && !validationUserIdErrorStatus) && (
            <div className={styles.save}>
              <button onClick={onClickSaveUserChanges}>
                {t("UserEditPage.Save")}
              </button>
            </div>
          )
          }
          {/* gender */}
          {(authorizedUser?.customId === userId) ? (
            <div className={styles.change_gender_wrap}>

              <button className={
                changeGenderFormStatus ?
                  styles.change_gender_wrap_main_button_open
                  : styles.change_gender_wrap_main_button} onClick={() => setChangeGenderFormStatus(!changeGenderFormStatus)}>
                {getGenderButtonText()}
              </button>

              {changeGenderFormStatus && (
                <div className={styles.change_gender_form}>
                  <div className={styles.gender_options_wrap}>

                    <div className={styles.gender_options_choice}>

                      <button
                        className={`${styles.gender_button} ${authorizedUser?.profile?.gender?.type === 'female' ? styles.active : ''
                          }`}
                        onClick={() => onClickGender('female')}
                      >
                        {capitalize(t("UserEditPage.Female"))}
                      </button>

                      <button
                        className={`${styles.gender_button} ${authorizedUser?.profile?.gender?.type === 'male' ? styles.active : ''
                          }`}
                        onClick={() => onClickGender('male')}
                      >
                        {capitalize(t("UserEditPage.Male"))}
                      </button>

                      <button
                        className={`${styles.gender_button} ${authorizedUser?.profile?.gender?.type === 'unspecified' ? styles.active : ''
                          }`}
                        onClick={() => onClickGender('unspecified')}
                      >
                        {capitalize(t("UserEditPage.Unspecified"))}
                      </button>
                    </div>
                    {/* ⚠️ ATTENTION, DANGER ZONE ❗❗❗
Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
After uncommenting this code, gender customization will be enabled, related code in - user.controller.js ⬇️ */}

                    {/*<div className={styles.custom_gender_wrap}>
                      <input
                        className={`${styles.custom_gender_input} ${authorizedUser?.profile?.gender?.type === 'custom' ? styles.active : ''
                          }`}
                        type="text"
                        placeholder={(authorizedUser?.profile?.gender?.type === 'custom') ? authorizedUser?.profile?.gender?.customValue : t("UserEditPage.CustomGender")}
                        value={customGender}
                        onChange={onChangeCustomGender}
                        maxLength={50}
                      />
                      {customGender.length > 0 && (
                        <button
                          onClick={onSubmitCustomGender}
                        >
                          OK
                        </button>
                      )}
                    </div>*/}

                    {/* /⚠️ ATTENTION, DANGER ZONE ❗❗❗⬆️
Before enabling the custom field, thoroughly review your country's legislation, as it may entail criminal liability, when using this field in a production environment in some countries.
After uncommenting this code, gender customization will be enabled, related code in - user.controller.js */}
                  </div>
                  {saveGender.isError && (
                    <div className={styles.gender_error}>
                      <p>{t("UserEditPage.GenderError", { message: serverMessage })}</p>
                    </div>
                  )}
                </div>
              )}
            </div>
          ) : null}
          {/* /gender */}
          {userAuthorizationCheckToChangePassword && (
            <div
              className={styles.change_password_wrap}
            >
              <button onClick={() => { setChangePasswordFormStatus(!changePasswordFormStatus) }}>
                {changePasswordFormStatus
                  ? t("UserEditPage.Hide")
                  : t("UserEditPage.ChangePassword")}
              </button>

              {changePasswordFormStatus && (
                <div
                  className={styles.change_password_form}
                >
                  <form className={styles.change_password_form_wrap}>
                    <div className={styles.change_password_input_errors_wrap}>
                      <div className={styles.change_password_input}>
                        <input
                          className={styles.old_password}
                          key='OldPassword'
                          type={showOldPassword ? "text" : "password"}
                          label="password"
                          autoComplete="off"
                          maxLength={50}
                          minLength={8}
                          placeholder={t(
                            "UserEditPage.OldPassword"
                          )}
                          onChange={onChangeOldPassword}
                          ref={oldPasswordInputRef}
                        />
                        <div
                          onClick={() => { setShowOldPassword(!showOldPassword) }}
                          className={styles.show_password}
                        >
                          {showOldPassword ? <EyeIconSecondVersionIcon /> : <ClosedEyeSecondVersionIcon />}
                        </div>
                      </div>
                      {serverMessage === "Old password is incorrect" && (
                        <div className={styles.change_password_input_errors_server}>
                          <p>
                            {t(
                              "UserEditPage.OldPasswordIncorrect"
                            )}
                          </p>
                        </div>
                      )}
                    </div>
                    <div className={styles.change_password_input_errors_wrap}>
                      <div className={styles.change_password_input_counter_wrap}>
                        <div className={styles.change_password_input}>
                          <input
                            className={styles.new_password}
                            key='NewPassword'
                            type={showNewPassword ? "text" : "password"}
                            label="password"
                            autoComplete="off"
                            placeholder={t(
                              "UserEditPage.NewPassword"
                            )}
                            onChange={onChangeNewPassword}
                            maxLength={50}
                            minLength={8}
                            ref={newPasswordInputRef}
                          />
                          <div
                            onClick={() => { setShowNewPassword(!showNewPassword) }}
                            className={styles.show_password}
                          >
                            {showNewPassword ? <EyeIconSecondVersionIcon /> : <ClosedEyeSecondVersionIcon />}
                          </div>
                        </div>
                        {characterCounterNewPassword > 0 && (
                          <div className={styles.letter_counter}>
                            <p>min 8 | {characterCounterNewPassword}/50</p>
                          </div>
                        )}
                      </div>
                      <div className={styles.password_requirements}>
                        <p>
                          {t(
                            "UserEditPage.PasswordRequirements"
                          )}
                        </p>
                      </div>
                      {serverMessage === "Password successfully changed" && (
                        <div className={styles.change_password_success}>
                          <p>
                            {t(
                              "UserEditPage.PasswordSuccessfullyChanged"
                            )}
                          </p>
                        </div>
                      )}
                    </div>
                  </form>
                  {(validatingNewPassword && (oldPassword?.length > 0) && (oldPassword !== newPassword)) && (
                    < button className={styles.change_password} onClick={onClickChangePassword}>
                      {t("UserEditPage.ChangePassword")}
                    </button>
                  )}
                </div>
              )}
            </div >
          )}

          {(userAuthorizationCheck !== undefined) && (
            <>
              {userHavePosts && (
                <div
                  className={styles.delete_all_user_posts}
                >
                  {!deleteAllPostsByUserMutation.isPending && (
                    <button onClick={onClickDeleteAllPostsByUser}>
                      {userAuthorizationCheck
                        ? t("UserEditPage.DeleteAllUserPostsButton")
                        : t("UserEditPage.DeleteAllYourPostsButton")}
                    </button>
                  )}
                  {deleteAllPostsByUserMutation.isPending && (
                    <div className={styles.loader_delete_all_posts_by_user_wrap}>
                      <div className={styles.loader_delete_all_posts_by_user}>
                        <Loader />
                      </div>
                    </div>
                  )}
                </div>
              )}
              {serverPostsDeletedMessage === "All posts deleted" && (
                <div className={styles.server_message_all_posts_deleted}>
                  <p>{t("UserEditPage.AllPostsDeleted")}</p>
                </div>
              )}
              <div className={styles.delete_user_account}>
                <button onClick={onClickDeleteUserAccount}>
                  {t("UserEditPage.DeleteAccount")}
                </button>
              </div>
              {(authorizedUser?.customId === userId) ? (
                <>
                  <div className={styles.settings}>
                    <h2>{t("UserEditPage.Settings")}</h2>
                  </div>
                  <div className={styles.interface_settings}>
                    <h3>{t("UserEditPage.Interface")}</h3>
                  </div>
                  <div className={styles.hide_gif}>
                    <button onClick={onClickHideGif}>
                      {authorizedUser?.settings.interface.hideGif
                        ? t("UserEditPage.ShowGif")
                        : t("UserEditPage.HideGif")}
                    </button>
                  </div>
                  <div className={styles.privacy_settings}>
                    <h3>{t("UserEditPage.Privacy")}</h3>
                  </div>
                  {/* hide gender */}
                  <div className={styles.hide_gender}>
                    <button onClick={onClickHideGender}>
                      {authorizedUser?.settings.privacy.hideGender
                        ? t("UserEditPage.ShowGender")
                        : t("UserEditPage.HideGender")}
                    </button>
                  </div>
                  {/* /hide gender */}
                </>
              ) : null}
            </>
          )}
          <div className={styles.back}>
            <button onClick={() => navigate("/" + userId)}>
              {t("PostCreatePage.Back")}
            </button>
          </div>
        </div >
      )
      }

    </>
  );
}
