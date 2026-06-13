// formatLinksInText.jsx

import { Link } from 'react-router-dom';

// Regular expression for any Unicode letters (\p{L}), numbers, hyphens and underscores.
// This set ensures that the tag is safe to use in a URL.
const HASHTAG_VALIDATION_REGEX = /^[\p{L}0-9_-]+$/u;

// Checking the validity of a tag to convert into a link.
const isTagValidForLink = (tag) => {
  // The check is carried out on a tag without the '#' symbol.
  return HASHTAG_VALIDATION_REGEX.test(tag);
};

const stripEndingPunctuation = (str = '') => {
  const match = str.match(/^(.+?)([.,)(])?$/);
  return {
    core: match?.[1] || str,
    punctuation: match?.[2] || '',
  };
};

const formatDisplayUrl = (url) => {
  try {
    const parsed = new URL(url);

    // remove display - www.
    let host = parsed.host.replace(/^www\./, '');
    let pathname = parsed.pathname;

    // remove trailing slash display
    if (pathname.endsWith('/')) {
      pathname = pathname.slice(0, -1);
    }

    return host + pathname;
  } catch (e) {
    return url;
  }
};


export const formatLinksInText = (text = '') => {
  const lines = text.split(/\r?\n/);

  const formatted = lines.flatMap((line, lineIndex) => {
    const words = line.split(/\s+/);
    const jsxWords = words.map((str, wordIndex) => {
      const { core, punctuation } = stripEndingPunctuation(str);

      if (core.startsWith('#')) {
        const tag = core.slice(1);

        // We turn only valid hashtags into links
        if (isTagValidForLink(tag)) {
          return (
            <span key={`tag-${lineIndex}-${wordIndex}`}>
              <Link to={`/hashtags/${tag}`}>#{tag}</Link>{punctuation + ' '}
            </span>
          );
        }

        // If the tag is invalid, return it as plain text
        return str + ' ';
      }

      if (core.startsWith('http://') || core.startsWith('https://')) {
        return (
          <span key={`link-${lineIndex}-${wordIndex}`}>
            <Link
              to={core}
              target="_blank"
              rel="noreferrer noopener"
            >
              {formatDisplayUrl(core)}
            </Link>
            {punctuation + ' '}
          </span>
        );
      }

      return str + ' ';
    });

    if (lineIndex < lines.length - 1) {
      jsxWords.push(<br key={`br-${lineIndex}`} />);
    }

    return jsxWords;
  });

  return formatted;
};