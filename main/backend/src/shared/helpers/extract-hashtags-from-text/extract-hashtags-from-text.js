// extract-hashtags-from-text.js

// Regex for any Unicode letters (\p{L}), numbers, hyphens and underscores.
// The 'u' flag is required for \p{L} to work.
const HASHTAG_VALIDATION_REGEX = /^[\p{L}0-9_-]+$/u;

// length and number of hashtags
const MAX_HASHTAGS_COUNT = 30;
const MAX_HASHTAG_LENGTH = 70;

// Clears the tag of trailing punctuation and forces it to lower case for DB.
export const cleanHashtag = (tag) => {
    if (typeof tag !== 'string') return '';
    // We remove only punctuation marks that can complete the word
    return tag.replace(/[.,)(]$/, '').toLowerCase();
};

// Checks that the tag consists only of allowed characters (any letters, numbers, -, _)
export const isHashtagValid = (cleanedTag) => {
    // The check is performed on a tag without the '#' symbol and without trailing punctuation.
    return HASHTAG_VALIDATION_REGEX.test(cleanedTag);
};

// Extracts only pure, unique and VALID tags (without '#') from an array of strings (words).
export const takeHashtags = (rawWords) => {
    const cleanedAndValidTags = rawWords
        // 1. Filter those that start with '#'
        .filter(v => typeof v === 'string' && v.startsWith('#'))
        // 2. Remove '#' and clear punctuation (cleanHashtag makes lowercase)
        .map(rawTag => cleanHashtag(rawTag.slice(1)))
        // 3. Filtering empty lines or tags with invalid characters
        .filter(tag => tag.length > 0 && isHashtagValid(tag));

    return [...new Set(cleanedAndValidTags)];
};

// Validation by length and quantity for controllers
export const validateHashtagsForPost = (tags) => {
    if (tags.length > MAX_HASHTAGS_COUNT) {
        return { valid: false, message: `Maximum ${MAX_HASHTAGS_COUNT} hashtags allowed` };
    }
    if (tags.some(tag => tag.length > MAX_HASHTAG_LENGTH)) {
        return { valid: false, message: `Each hashtag must be ${MAX_HASHTAG_LENGTH} characters or less` };
    }
    return { valid: true };
};