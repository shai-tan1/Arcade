/**
 * Converts an image file to WebP format with optional size compression and max dimension limits. GIF format is not converted, but simply skipped.
 *
 * @param {File} file - The input image file (e.g., JPEG, PNG, WebP, GIF).
 * @param {Object} options - Conversion options.
 * @param {string} [options.newFileName='converted.webp'] - The name of the new WebP file.
 * @param {number|null} [options.targetSizeBytes=null] - Target file size in bytes (e.g., 307200 for 300KB). If not set, maximum quality is used.
 * @param {number} [options.fallbackQuality=0.6] - Fallback quality used if target size is not achieved.
 * @param {number|null} [options.maxWidthOrHeight=null] - Maximum width or height (whichever is greater) for downscaling before compression.
 * @param {function|null} [options.onProgress=null] - Optional callback function to track progress (0 to 100).
 *
 * @returns {Promise<File>} - A Promise that resolves to the converted WebP file.
 */

export async function convertImage(file, options = {}) {
    const {
        newFileName = 'converted.webp',
        targetSizeBytes = null,
        fallbackQuality = 0.6,
        maxWidthOrHeight = null,
        onProgress = null
    } = options;

    // if GIF, return file without conversion
    if (file.type === 'image/gif') {
        if (onProgress) onProgress(100);
        return file;
    }
    // /if GIF, return file without conversion 

    const imageBitmap = await createImageBitmap(file);

    let targetWidth = imageBitmap.width;
    let targetHeight = imageBitmap.height;

    if (maxWidthOrHeight) {
        const ratio = imageBitmap.width / imageBitmap.height;

        if (imageBitmap.width > imageBitmap.height) {
            if (imageBitmap.width > maxWidthOrHeight) {
                targetWidth = maxWidthOrHeight;
                targetHeight = Math.round(maxWidthOrHeight / ratio);
            }
        } else {
            if (imageBitmap.height > maxWidthOrHeight) {
                targetHeight = maxWidthOrHeight;
                targetWidth = Math.round(maxWidthOrHeight * ratio);
            }
        }
    }

    const canvas = document.createElement('canvas');
    canvas.width = targetWidth;
    canvas.height = targetHeight;

    const ctx = canvas.getContext('2d');
    ctx.drawImage(imageBitmap, 0, 0, targetWidth, targetHeight);

    const createBlobWithQuality = (quality) =>
        new Promise((resolve, reject) => {
            canvas.toBlob((blob) => {
                if (!blob) return reject(new Error('Failed to convert canvas to WebP blob'));
                resolve(blob);
            }, 'image/webp', quality);
        });

    // if the target size is not specified, we give the maximum quality
    if (!targetSizeBytes) {
        const blob = await createBlobWithQuality(1);
        if (onProgress) onProgress(100);
        return new File([blob], newFileName, {
            type: 'image/webp',
            lastModified: Date.now(),
        });
    }

    // otherwise we select the quality for the given size
    let minQuality = 0.3;
    let maxQuality = 1;
    let bestBlob = null;


    for (let i = 0; i < 7; i++) {
        const midQuality = (minQuality + maxQuality) / 2;
        const blob = await createBlobWithQuality(midQuality);

        const progress = Math.round(((i + 1) / 7) * 100);
        if (onProgress) onProgress(progress);

        if (Math.abs(blob.size - targetSizeBytes) <= targetSizeBytes * 0.1) {
            bestBlob = blob;
            break;
        }

        if (blob.size > targetSizeBytes) {
            maxQuality = midQuality;
        } else {
            bestBlob = blob;
            minQuality = midQuality;
        }
    }

    // if you don't get into the right range, then - fallback
    if (!bestBlob) {
        bestBlob = await createBlobWithQuality(fallbackQuality);
    }

    if (onProgress) onProgress(100);

    return new File([bestBlob], newFileName, {
        type: 'image/webp',
        lastModified: Date.now(),
    });
}




