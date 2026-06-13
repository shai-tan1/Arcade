/*
Formats the date as follows:
Jul 4, 2025 · 10:45 PM
4 июля 2025 · 22:45
Gets the user's local time zone (e.g., 'Europe/Moscow', 'Europe/Berlin', 'America/New_York') for formatting dates in their local time.
*/

import { useTranslation } from 'react-i18next';

import { DotIcon } from "../../../../shared/ui";
import styles from './FormattedRegistrationDate.module.css';

export const useFormattedRegistrationDate = (dateString) => {
  const { i18n } = useTranslation();

  if (!dateString) return null;

  const date = new Date(dateString);
  const now = new Date();
  const lang = i18n.language;
  const isCurrentYear = date.getFullYear() === now.getFullYear();

  // gets the user's local time zone
  const userTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  let datePart = '';
  let timePart = '';

  if (lang === 'ru') {
    datePart = date.toLocaleDateString('ru-RU', {
      day: 'numeric',
      month: 'long',
      ...(isCurrentYear ? {} : { year: 'numeric' }),
      timeZone: userTimeZone,
    }).replace(/\s?г\.$/, '');

    timePart = date.toLocaleTimeString('ru-RU', {
      hour: '2-digit',
      minute: '2-digit',
      timeZone: userTimeZone,
    });
  } else {
    datePart = date.toLocaleDateString('en-US', {
      month: 'long',
      day: 'numeric',
      ...(isCurrentYear ? {} : { year: 'numeric' }),
      timeZone: userTimeZone,
    });

    timePart = date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      hour12: true,
      timeZone: userTimeZone,
    });
  }

  return {
    isCurrentYear,
    element: (
      <div className={styles.formatted_registration_date_wrap}>
        <p>{datePart}</p>
        <div className={styles.separator}><DotIcon /></div>
        <p>{timePart}</p>
      </div>
    )
  };
};
