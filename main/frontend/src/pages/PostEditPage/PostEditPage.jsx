import {
  useState,
  useRef,
  useEffect
} from "react";
import { useSelector } from "react-redux";
import {
  useNavigate,
  Navigate,
  useParams
} from "react-router-dom";
import { useTranslation } from "react-i18next";
import TextareaAutosize from "react-textarea-autosize";
import {
  useQuery,
  useMutation,
  useQueryClient
} from "@tanstack/react-query";

import { httpClient } from "../../shared/api";
import { API_BASE_URL } from '../../shared/constants';
import { convertImage } from '../../shared/utils';
import {
  LoadingBar,
  Loader
} from "../../shared/ui";
import { NotFoundPage } from "../../pages";

import styles from "./PostEditPage.module.css";

export function PostEditPage() {

  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { postId } = useParams();
  const { t } = useTranslation();

  const post = useQuery({
    queryKey: ['posts', "editPostPage", postId],
    refetchOnWindowFocus: false,
    retry: false,
    queryFn: () =>
      httpClient
        .get(`/posts/${postId}/edit`)
        .then((response) => {
          return response;
        }),
  });

  // main image
  const [
    databaseMainImageUri,
    setDatabaseMainImageUri
  ] = useState();

  const [
    databaseMainImageUriUpdate,
    setDatabaseMainImageUriUpdate
  ] = useState();

  const mainImageFileRef = useRef();
  const [mainImageUrl, setMainImageUrl] = useState();

  const [
    mainImageFileUrl,
    setMainImageFileUrl
  ] = useState();
  
  const [mainImageFile, setMainImageFile] = useState();

  const [
    checkMainImageUpdate,
    setCheckMainImageUpdate
  ] = useState(false);

  // main image loading and error status

  const [
    mainImageLoadingStatus,
    setMainImageLoadingStatus
  ] = useState(false);

  const [
    mainImageLoadingStatusError,
    setMainImageLoadingStatusError
  ] = useState(false);

  useEffect(() => {
    if (mainImageLoadingStatus === 100) {
      setTimeout(() => {
        setMainImageLoadingStatus(false);
      }, "500");
    }
    if (mainImageLoadingStatusError) {
      setTimeout(() => {
        setMainImageLoadingStatusError(false);
      }, "3500");
    }
  }, [
    mainImageLoadingStatus,
    mainImageLoadingStatusError
  ]);

  // convert image
  async function onChangeConvertMainImage(event) {
    setMainImageLoadingStatusError(false);
    setMainImageLoadingStatus(0);
    const imageFile = event.target.files[0];

    try {
      let webpFile;
      if (imageFile.type === 'image/gif') {
        for (let i = 0; i <= 100; i += 5) {
          await new Promise(res => setTimeout(res, 10));
          setMainImageLoadingStatus(i);
        }
        webpFile = imageFile;
      } else {
        webpFile = await convertImage(imageFile, {
          newFileName: 'image.webp',
          targetSizeBytes: 307200,
          fallbackQuality: 0.1,
          maxWidthOrHeight: 1920,
          onProgress: (progress) => {
            setMainImageLoadingStatus(progress);
          }
        });
      }
      setMainImageFile(webpFile);
      setMainImageFileUrl(URL.createObjectURL(webpFile));
      setCheckMainImageUpdate(true);
      setMainImageUrl(null);
      setTimeout(() => setMainImageLoadingStatus(false), 300);
      setMainImageLoadingStatusError(false);
    } catch (error) {
      console.log(error);
      setMainImageLoadingStatusError(true);
      setMainImageLoadingStatus(false);
    }
  }

  // title
  const titleRef = useRef();
  const [title, setTitle] = useState("");
  const [enteredTitle, setEnteredTitle] = useState("");

  const [
    titleValueDatabase,
    setTitleValueDatabase
  ] = useState();

  const [
    numberCharactersInTitle,
    setNumberCharactersInTitle
  ] = useState();

  const onChangeTitle = (event) => {
    setNumberCharactersInTitle(event.target.value.length);
    setTitle(event.target.value);
    setEnteredTitle(event.target.value);
    setChangeTitleCheck(true);
  };

  // text
  const textRef = useRef();
  const [text, setText] = useState("");
  const [enteredText, setEnteredText] = useState("");

  const [
    textValueDatabase,
    setTextValueDatabase
  ] = useState();

  const [
    numberCharactersInText,
    setNumberCharactersInText
  ] = useState();

  const onChangeText = (event) => {
    setNumberCharactersInText(event.target.value.length);
    setText(event.target.value);
    setEnteredText(event.target.value);
    setChangeTextCheck(true);
  };

  const [
    changeTitleCheck,
    setChangeTitleCheck
  ] = useState(false);

  const [
    changeTextCheck,
    setChangeTextCheck
  ] = useState(false);

  const [
    permissionSavePost,
    setPermissionSavePost
  ] = useState(false);

  const changePostMutation = useMutation({
    mutationKey: ['changePost'],
    mutationFn: async () => {
      const baseFields = { text, title };

      if (mainImageFile instanceof File) {
        const formData = new FormData();
        formData.append("image", mainImageFile);
        const { imageUri: mainImageUri } = await httpClient.post(`/posts/${postId}/image`, formData);
        const updateFields = { ...baseFields, mainImageUri };
        await httpClient.patch(`/posts/${postId}`, updateFields);
      } else {
        const updateFields = { ...baseFields, mainImageUri: databaseMainImageUriUpdate };
        await httpClient.patch(`/posts/${postId}`, updateFields);
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      queryClient.invalidateQueries({ queryKey: ['users'] });
      queryClient.invalidateQueries({ queryKey: ['me'] });
      navigate(`/posts/${postId}`);
    },
    onError: (error) => {
      console.warn("❌ Error while editing post:", error);
      if (error?.error === "File size exceeds 2.5 MB limit.") {
        alert(t("Common.LargeImageError"));
      } else {
        alert(t("PostEditPage.FailedSaveChanges"));
      }
    },
  });

  const onClickChangePost = () => {
    changePostMutation.mutate();
  };

  useEffect(() => {
    if (title !== enteredTitle) {
      setChangeTitleCheck(false);
    }

    if (text !== enteredText) {
      setChangeTextCheck(false);
    }

    if (titleValueDatabase === enteredTitle) {
      setEnteredTitle(null);
    }

    if (textValueDatabase === enteredText) {
      setEnteredText(null);
    }

    if (titleValueDatabase === title) {
      setNumberCharactersInTitle(null);
      setChangeTitleCheck(false);
      setPermissionSavePost(false);
    }

    if (textValueDatabase === text) {
      setNumberCharactersInText(null);
      setChangeTextCheck(false);
      setPermissionSavePost(false);
    }

    if (
      post.isSuccess && (
        changeTitleCheck ||
        textValueDatabase !== text ||
        checkMainImageUpdate
      )
    ) {
      setPermissionSavePost(true);
    }
  }, [
    titleValueDatabase,
    title,
    textValueDatabase,
    text,
    enteredTitle,
    enteredText,
    databaseMainImageUri,
    mainImageFileUrl,
    mainImageUrl,
    checkMainImageUpdate,
    changeTitleCheck,
    changeTextCheck,
    permissionSavePost
  ]);

  useEffect(() => {
    setTitle(post.data?.title);
    setTitleValueDatabase(post.data?.title);
    setText(post.data?.text);
    setTextValueDatabase(post.data?.text);
    setDatabaseMainImageUri(
      post.data?.mainImageUri && (/^https?:\/\//.test(post.data.mainImageUri) ? post.data.mainImageUri : API_BASE_URL + post.data.mainImageUri),
    );
    setMainImageUrl(
      post.data?.mainImageUri && (/^https?:\/\//.test(post.data.mainImageUri) ? post.data.mainImageUri : API_BASE_URL + post.data.mainImageUri),
    );
    setDatabaseMainImageUriUpdate(post.data?.mainImageUri);
  }, [post.data]);

  const onClickRemoveImage = () => {
    setDatabaseMainImageUriUpdate(null);
    setMainImageFileUrl(null);
    setDatabaseMainImageUri(null);
    setMainImageUrl(null);
    setMainImageFile(null);
    setCheckMainImageUpdate(true);
    setCheckMainImageUpdate(!checkMainImageUpdate);
    mainImageFileRef.current.value = null;
  };

  if (post.error?.message === "No access") {
    return <Navigate to="/" />;
  }

  return (
    <>
      {post.isPending && (
        <div className={styles.loader_wrap}>
          <div className={styles.loader}>
            <Loader />
          </div>
        </div>
      )}
      {post.isSuccess && (
        <div
          className={styles.edit_post}
          data-edit-post-page-dark-theme={darkThemeStatus}
        >
          <div className={styles.title}>
            <h1>{t("PostEditPage.EditPost")}</h1>
          </div>
          {(post.error?.response?.message === "Post not found" || post.isError) && <NotFoundPage />}
          {post.isSuccess && (
            <>
              {(mainImageUrl || mainImageFile) && (
                <div className={styles.main_image}>
                  <img alt="" src={mainImageUrl || mainImageFileUrl} />
                </div>
              )}
              {mainImageLoadingStatus ? (
                <div className={styles.main_image_loading_bar_wrap}>
                  <div className={styles.main_image_loading_bar}>
                    <LoadingBar value={mainImageLoadingStatus} />
                  </div>
                </div>
              ) : null}
              {mainImageLoadingStatusError && (
                <div className={styles.main_image_loading_status_error_wrap}>
                  <div className={styles.main_image_loading_status_error}>
                    <p>{t("SystemMessages.Error")}</p>
                  </div>
                </div>
              )}
              <div className={styles.add_delete_main_image_buttons_wrap}>
                <button onClick={() => mainImageFileRef.current.click()}>
                  {databaseMainImageUri || mainImageFileUrl
                    ? t("PostEditPage.Change")
                    : t("PostEditPage.AddMainImage")}
                </button>
                {(mainImageUrl || mainImageFile) && (
                  <button onClick={onClickRemoveImage}>{t("PostEditPage.Delete")}</button>
                )}
              </div>
              <div className={styles.post_title}>
                <TextareaAutosize
                  type="text"
                  maxLength={220}
                  ref={titleRef}
                  value={title}
                  variant="standard"
                  placeholder={t("PostEditPage.Title")}
                  onChange={onChangeTitle}
                />
              </div>
              {numberCharactersInTitle > 0 && (
                <div className={styles.post_title_letter_counter}>
                  <p>{numberCharactersInTitle}/220</p>
                </div>
              )}
              <div className={styles.text}>
                <TextareaAutosize
                  type="text"
                  maxLength={75000}
                  value={text}
                  ref={textRef}
                  onChange={onChangeText}
                  variant="standard"
                  placeholder={
                    (mainImageUrl || mainImageFileUrl ? "" : "* ") +
                    t("PostEditPage.Text")
                  }
                />
              </div>
              {numberCharactersInText > 0 && (
                <div className={styles.text_letter_counter}>
                  <p>{numberCharactersInText}/75000</p>
                </div>
              )}
              <div className={styles.publish_post_back_buttons_wrap}>
                <div className={styles.publish_post_back_buttons}>
                  <div className={styles.back}>
                    <button onClick={() => navigate(-1)}>
                      {t("PostEditPage.Back")}
                    </button>
                  </div>
                  {(
                    permissionSavePost &&
                    !changePostMutation.isPending
                  ) && (
                      <div className={styles.publish_post}>
                        <button onClick={onClickChangePost}>
                          {t("PostEditPage.Publish")}
                        </button>
                      </div>
                    )}
                  {changePostMutation.isPending && (
                    <div className={styles.creating_post_loader_wrap}>
                      <div className={styles.creating_post_loader}>
                        <Loader />
                      </div>
                    </div>
                  )}
                </div>
              </div>
              <input
                ref={mainImageFileRef}
                type="file"
                accept="image/*"
                onChange={(event) => onChangeConvertMainImage(event)}
                hidden
              />
            </>
          )}
        </div>
      )}
    </>
  );
}