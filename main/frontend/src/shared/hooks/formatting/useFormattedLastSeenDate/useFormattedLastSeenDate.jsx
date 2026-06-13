import { useTranslation } from 'react-i18next';

export const useFormattedLastSeenDate = (dateString, genderType = 'unspecified') => {
  const { t, i18n } = useTranslation();
  if (!dateString) return '';

  const date = new Date(dateString);
  const now = new Date();
  const diffSeconds = Math.floor((now - date) / 1000);
  if (diffSeconds < 0) return '';

  const lang = i18n.language;

  // Префикс по полу
  let prefix = '';
  if (lang === 'ru') {
    if (genderType === 'male') prefix = t('UseFormattedLastSeenDate.prefix_male');
    else if (genderType === 'female') prefix = t('UseFormattedLastSeenDate.prefix_female');
    else prefix = t('UseFormattedLastSeenDate.prefix_unspecified');
  } else {
    prefix = t('UseFormattedLastSeenDate.prefix');
  }

  const formatTime = (d) => d.toLocaleTimeString(lang === 'ru' ? 'ru-RU' : 'en-US', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: lang !== 'ru'
  });

  // < 1 мин
  if (diffSeconds < 60) {
    const sec = diffSeconds;
    return `${prefix} ${sec} ${t('UseFormattedLastSeenDate.seconds', { count: sec })} ${t('UseFormattedLastSeenDate.ago')}`;
  }

  // < 1 час
  if (diffSeconds < 3600) {
    const min = Math.floor(diffSeconds / 60);
    return `${prefix} ${min} ${t('UseFormattedLastSeenDate.minutes', { count: min })} ${t('UseFormattedLastSeenDate.ago')}`;
  }

  // < 1 день
  if (diffSeconds < 86400) {
    const hours = Math.floor(diffSeconds / 3600);
    return `${prefix} ${hours} ${t('UseFormattedLastSeenDate.hours', { count: hours })} ${t('UseFormattedLastSeenDate.ago')}`;
  }

  // Вчера
  const yesterday = new Date();
  yesterday.setDate(now.getDate() - 1);
  if (
    date.getDate() === yesterday.getDate() &&
    date.getMonth() === yesterday.getMonth() &&
    date.getFullYear() === yesterday.getFullYear()
  ) {
    return `${prefix} ${t('UseFormattedLastSeenDate.yesterday')} ${t('UseFormattedLastSeenDate.at')} ${formatTime(date)}`;
  }

  // Меньше года
  if (diffSeconds < 31536000) {
    const datePart = date.toLocaleDateString(lang === 'ru' ? 'ru-RU' : 'en-US', {
      day: 'numeric',
      month: 'long'
    });
    return `${prefix} ${datePart} ${t('UseFormattedLastSeenDate.at')} ${formatTime(date)}`;
  }

  // Больше года — убираем "г." в русском
  let datePart = date.toLocaleDateString(lang === 'ru' ? 'ru-RU' : 'en-US', {
    day: 'numeric',
    month: 'long',
    year: 'numeric'
  });
  if (lang === 'ru') datePart = datePart.replace(/\sг\.?$/, '');

  return `${prefix} ${datePart} ${t('UseFormattedLastSeenDate.at')} ${formatTime(date)}`;
};
