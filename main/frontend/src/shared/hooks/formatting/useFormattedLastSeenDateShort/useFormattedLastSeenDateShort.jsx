// frontend/src/shared/hooks/useFormattedLastSeenDateShort.jsx
/*
Formats the lastSeen date in short form, e.g., '27 c' for 27 seconds ago, '3 мин' for 3 minutes ago, with support for translations and plurals.
Handles seconds, minutes, hours, days, months, years.
If lastSeen is null or in the future, returns an empty string.
*/

import { useTranslation } from 'react-i18next';

export const useFormattedLastSeenDateShort = (dateString) => {
  const { t } = useTranslation();

  if (!dateString) return '';

  const date = new Date(dateString);
  const now = new Date();

  // Calculate difference in seconds
  const diffSeconds = Math.floor((now - date) / 1000);

  if (diffSeconds < 0) return ''; // Future date, ignore

  if (diffSeconds < 60) {
    return `${diffSeconds} ${t('UseFormattedLastSeenDateShort.seconds')}`;
  }
  else if (diffSeconds < 3600) {
    const minutes = Math.floor(diffSeconds / 60);
    return `${minutes} ${t('UseFormattedLastSeenDateShort.minutes')}`;
  }
  else if (diffSeconds < 86400) {
    const hours = Math.floor(diffSeconds / 3600);
    return `${hours} ${t('UseFormattedLastSeenDateShort.hours')}`;
  }
  else if (diffSeconds < 2592000) { // Less than 30 days
    const days = Math.floor(diffSeconds / 86400);
    return `${days} ${t('UseFormattedLastSeenDateShort.days')}`; // Assume 'days' translation added: 'd' for EN, 'д' for RU
  }
  else if (diffSeconds < 31536000) { // Less than 365 days
    const months = Math.floor(diffSeconds / 2592000);
    return `${months} ${t('UseFormattedLastSeenDateShort.months')}`;
  }
  else {
    const years = Math.floor(diffSeconds / 31536000);
    return `${years} ${t('UseFormattedLastSeenDateShort.key', { count: years })}`;
  }
};