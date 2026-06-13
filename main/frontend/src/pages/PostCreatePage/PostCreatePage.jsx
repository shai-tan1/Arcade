import {
  useRef,
  useEffect,
  useState
} from "react";
import {
  useSelector,
  useDispatch
} from "react-redux";
import {
  useMutation,
  useQueryClient
} from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import TextareaAutosize from "react-textarea-autosize";

import { httpClient } from "../../shared/api";
import { setShowAccessModal } from "../../features/accessModal/accessModalSlice";
import { convertImage } from '../../shared/utils';
import {
  LoadingBar,
  Loader
} from "../../shared/ui";

import styles from "./PostCreatePage.module.css";

export function PostCreatePage() {
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);
  const logInStatus = useSelector((state) => state.logInStatus);
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { t } = useTranslation();
  const dispatch = useDispatch();
  const accessModalStatus = useSelector((state) => state.accessModal);

  // main image
  const mainImageFileRef = useRef();

  const [
    mainImageFileUrl,
    setMainImageFileUrl
  ] = useState();

  const [mainImageFile, setMainImageFile] = useState();

  const onClickRemoveFileMainImage = () => {
    setMainImageFileUrl(null);
    setMainImageFile(null);
    mainImageFileRef.current.value = null;
  };

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
        webpFile = await convertImage(
          imageFile,
          {
            newFileName: 'image.webp',
            targetSizeBytes: 307200,
            fallbackQuality: 0.6,
            maxWidthOrHeight: 1920,
            onProgress: (progress) => {
              setMainImageLoadingStatus(progress);
            }
          }
        );
      }

      setMainImageFile(webpFile);
      setMainImageFileUrl(URL.createObjectURL(webpFile));
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

  const [
    titleCharacterCounter,
    setTitleCharacterCounter
  ] = useState();

  const onChangeTitle = (event) => {
    setTitle(event.target.value);
    setTitleCharacterCounter(event.target.value.length);
  };

  // text
  const textRef = useRef();
  const [text, setText] = useState("");

  const [
    textCharacterCounter,
    setTextCharacterCounter
  ] = useState();

  const onChangeText = (event) => {
    setText(event.target.value);
    setTextCharacterCounter(event.target.value.length);
  };

  const createPostMutation = useMutation({
    mutationKey: ['createPost'],
    mutationFn: async () => {
      const createFields = { text, title, mainImageUri: mainImageFileUrl };
      const { _id: postId } = await httpClient.post("/posts/", createFields);

      if (mainImageFile instanceof File) {
        const formData = new FormData();
        formData.append("image", mainImageFile);

        try {
          const { imageUri: mainImageUri } = await httpClient.post(`/posts/${postId}/image`, formData);
          const updateFields = { text, title, mainImageUri };
          await httpClient.patch(`/posts/${postId}`, updateFields);
          return { postId };

        } catch (uploadErr) {
          // rollback: delete created post on image upload error
          await httpClient.delete(`/posts/${postId}`);
          throw uploadErr;
        }
      }

      return { postId };
    },
    onSuccess: ({ postId }) => {
      queryClient.invalidateQueries({ queryKey: ['posts'] });
      navigate(`/posts/${postId}`);
    },
    onError: (error) => {
      console.warn("❌ Error creating post:", error);
      if (error?.error === "File size exceeds 2.5 MB limit.") {
        alert(t("Common.LargeImageError"));
      } else {
        alert(t("Common.UploadingImageError"));
      }
    },
  });

  const onClickCreatePost = () => {
    if (!logInStatus) {
      dispatch(
        setShowAccessModal(
          !accessModalStatus.showAccessModal));
      return;
    }
    createPostMutation.mutate();
  };

  return (
    <div
      onClick={() =>
        !logInStatus &&
        dispatch(
          setShowAccessModal(
            !accessModalStatus.showAccessModal))
      }
      className={styles.create_post}
      data-creation-post-page-dark-theme={darkThemeStatus}
    >
      <div className={styles.title}>
        <h1>{t("PostCreatePage.CreatePost")}</h1>
      </div>
      {mainImageFileUrl && (
        <div className={styles.main_image}>
          <img alt="" src={mainImageFileUrl} />
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
        <button
          disabled={!logInStatus}
          onClick={() => mainImageFileRef.current.click()}
        >
          {mainImageFileUrl
            ? t("PostCreatePage.ChangeMainImage")
            : t("PostCreatePage.AddMainImage")}
        </button>
        {mainImageFileUrl && (
          <button
            disabled={!logInStatus}
            onClick={onClickRemoveFileMainImage}
          >
            {t("PostCreatePage.DeleteMainImage")}
          </button>
        )}
      </div>
      <div className={styles.post_title}>
        <TextareaAutosize
          type="text"
          maxLength={220}
          value={title}
          ref={titleRef}
          onChange={onChangeTitle}
          variant="standard"
          placeholder={t("PostCreatePage.Title")}
        />
      </div>
      {title && (
        <div className={styles.post_title_letter_counter}>
          <p>{titleCharacterCounter}/220</p>
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
            (mainImageFile ? "" : "* ") + t("PostCreatePage.Text")
          }
        />
        {text && (
          <div className={styles.text_letter_counter}>
            <p>{textCharacterCounter}/75000</p>
          </div>
        )}
      </div>
      <div className={styles.publish_post_back_buttons_wrap}>
        <div className={styles.publish_post_back_buttons}>
          <div className={styles.back}>
            <button onClick={() => navigate(-1)}>
              {t("PostCreatePage.Back")}
            </button>
          </div>
          {((mainImageFile || textCharacterCounter >= 1) && !createPostMutation.isPending) && (
            <div className={styles.publish_post}>
              <button onClick={onClickCreatePost}>
                {t("PostCreatePage.Publish")}
              </button>
            </div>
          )}
          {createPostMutation.isPending && (
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
    </div>
  );
}