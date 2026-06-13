import {
  useState,
  useEffect,
  useRef
} from "react";
import {
  useDispatch,
  useSelector
} from "react-redux";
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from "react-i18next";

import { httpClient } from "../../shared/api";
import {
  setShowMoreAboutUserModal,
  setUserId
} from "./moreAboutUserModalSlice";
import {
  useFormattedRegistrationDate
} from '../../shared/hooks';
import { Loader } from '../../shared/ui';

import styles from "./MoreAboutUserModal.module.css";

export function MoreAboutUserModal() {

  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const {
    showMoreAboutUserModal,
    userId
  } = useSelector((state) => state.moreAboutUserModal);

  const user = useQuery({
    queryKey: ['users', 'userProfilePageUserData', userId],
    queryFn: () => httpClient.get(`/users/${userId}`).then((response) => response),
    enabled: !!userId,
    refetchOnWindowFocus: true,
    retry: false,
  });

  const { t } = useTranslation();
  const dispatch = useDispatch();
  const [fadeOut, setFadeOut] = useState(false);

  // click tracking outside the modal
  const modalRef = useRef();
  useEffect(() => {
    if (modalRef.current) {
      const handler = (e) => {
        if (!modalRef.current.contains(e.target)) {
          setFadeOut(true);
        }
      };
      document.addEventListener("mousedown", handler);
      return () => {
        document.removeEventListener("mousedown", handler);
      };
    }
  });
  // /click tracking outside the modal


  // hide body scroll when modal is open
  useEffect(() => {
    showMoreAboutUserModal ?
      (document.body.style.overflow = "hidden")
      :
      (document.body.style.overflow = "auto");
  }, [showMoreAboutUserModal]);
  // /hide body scroll when modal is open

  // get gender text
  const getGenderText = () => {
    const genderType = user?.data?.profile?.gender?.type || 'unspecified';
    const translations = {
      male: t("MoreAboutUserModal.Male"),
      female: t("MoreAboutUserModal.Female"),
      unspecified: t("MoreAboutUserModal.Unspecified"),
      custom: user?.data?.profile?.gender?.customValue || t("MoreAboutUserModal.Unspecified"),
    };

    return translations[genderType];
  };
  // /get gender text

  const genderIsHidden = user?.data?.settings.privacy.hideGender;

  const genderNotSpecified = user?.data?.profile?.gender?.type == 'unspecified';

  // format registration date
  const registration = useFormattedRegistrationDate(
    user?.data?.createdAt
  );
  // /format registration date

  return (
    <>
      {showMoreAboutUserModal && (
        <>

          <div
            className={
              fadeOut
                ? `${styles.modal_background} ${styles.modal_background_fade_out}`
                : styles.modal_background
            }
            data-access-modal-dark-theme={darkThemeStatus}>
            <div
              className={
                fadeOut
                  ? `${styles.modal_wrap} ${styles.modal_wrap_fade_out}`
                  : `${styles.modal_wrap}`
              }
              onAnimationEnd={(e) => {
                if (e.animationName === styles.fadeOut) {
                  dispatch(setShowMoreAboutUserModal(!showMoreAboutUserModal));
                  dispatch(setUserId(null));
                  setFadeOut(false);
                }
              }}
            >
              <div
                ref={modalRef}
                className={styles.modal}
              >

                <div className={styles.additional_information_wrap}>

                  {user.isPending && (
                    <div className={styles.loader_wrap}>
                      <div className={styles.loader}>
                        <Loader />
                      </div>
                    </div>
                  )}

                  {user.isSuccess && (
                    <div className={styles.additional_information}>

                      <div className={styles.additional_information_title}>
                        <h2>{t("MoreAboutUserModal.DetailedInformation")}</h2>
                      </div>

                      <div className={styles.additional_information_content}>

                        {(!genderIsHidden && !genderNotSpecified) && (
                          <div className={styles.gender}>
                            <p><strong>{t("MoreAboutUserModal.Gender")}:</strong> {getGenderText()}</p>
                          </div>
                        )}

                        <div className={styles.registration_date}>
                          <p><strong>{t("MoreAboutUserModal.Registration")}:</strong></p> {registration?.element}
                        </div>

                      </div>
                    </div>
                  )}

                </div>
              </div>
            </div>
          </div>

        </>
      )}
    </>
  );
}
