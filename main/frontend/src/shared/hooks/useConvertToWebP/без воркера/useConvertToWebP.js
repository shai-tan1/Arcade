import { useState, useCallback } from 'react';

export function useConvertToWebP() {
  const [progress, setProgress] = useState(false);
  const [error, setError] = useState(false);

  const convert = useCallback(async (file, options = {}) => {
    setProgress(0);
    setError(false);

    const {
      newFileName = 'converted.webp',
      targetSizeBytes = null,
      fallbackQuality = 0.6,
      maxWidthOrHeight = null
    } = options;

    try {
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

      if (!targetSizeBytes) {
        const blob = await createBlobWithQuality(1);
        setProgress(100);
        return new File([blob], newFileName, {
          type: 'image/webp',
          lastModified: Date.now(),
        });
      }

      let minQuality = 0.3;
      let maxQuality = 1;
      let bestBlob = null;

      for (let i = 0; i < 7; i++) {
        const midQuality = (minQuality + maxQuality) / 2;
        const blob = await createBlobWithQuality(midQuality);

        const currentProgress = Math.round(((i + 1) / 7) * 100);
        setProgress(currentProgress);

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

      if (!bestBlob) {
        bestBlob = await createBlobWithQuality(fallbackQuality);
      }

      setProgress(100);

      return new File([bestBlob], newFileName, {
        type: 'image/webp',
        lastModified: Date.now(),
      });
    } catch (e) {
      console.error(e);
      setProgress(false);
      setError(true);
      throw e;
    }
  }, []);

  return { convertImage: convert, progress, error };
}
