// useConvertToWebP.js
import { useCallback, useState } from 'react';
import { webpWorkerCode } from './webpWorker';

export function useConvertToWebP({ useWebWorker = false } = {}) {
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState(false);

  const convert = useCallback(async (file, options = {}) => {
    setProgress(0);
    setError(false);

    if (useWebWorker) {
      return new Promise((resolve, reject) => {
        const blob = new Blob(
          [`(${webpWorkerCode.toString()})()`],
          { type: 'application/javascript' }
        );
        const worker = new Worker(URL.createObjectURL(blob));

        worker.onmessage = (e) => {
          const { file: newFile, error: err } = e.data;
          if (err) {
            setError(true);
            setProgress(false);
            reject(new Error(err));
          } else {
            setProgress(100);
            resolve(newFile);
          }
          worker.terminate();
        };

        worker.postMessage({ file, options });
      });
    }

    // Fallback без воркера (использует обычный canvas)
    return new Promise((resolve, reject) => {
      const reader = new FileReader();

      reader.onload = (event) => {
        const img = new Image();
        img.onload = async () => {
          try {
            const canvas = document.createElement('canvas');
            const ctx = canvas.getContext('2d');

            let targetWidth = img.width;
            let targetHeight = img.height;

            if (options.maxWidthOrHeight) {
              const ratio = img.width / img.height;
              if (img.width > img.height) {
                if (img.width > options.maxWidthOrHeight) {
                  targetWidth = options.maxWidthOrHeight;
                  targetHeight = Math.round(options.maxWidthOrHeight / ratio);
                }
              } else {
                if (img.height > options.maxWidthOrHeight) {
                  targetHeight = options.maxWidthOrHeight;
                  targetWidth = Math.round(options.maxWidthOrHeight * ratio);
                }
              }
            }

            canvas.width = targetWidth;
            canvas.height = targetHeight;
            ctx.drawImage(img, 0, 0, targetWidth, targetHeight);

            canvas.toBlob((blob) => {
              if (!blob) {
                reject(new Error('Conversion to WebP failed'));
                return;
              }
              const newFile = new File([blob], options.newFileName || 'converted.webp', {
                type: 'image/webp',
                lastModified: Date.now(),
              });
              setProgress(100);
              resolve(newFile);
            }, 'image/webp', 0.8);
          } catch (err) {
            setError(true);
            reject(err);
          }
        };

        img.onerror = () => {
          setError(true);
          reject(new Error('Image load failed'));
        };

        img.src = event.target.result;
      };

      reader.onerror = () => {
        setError(true);
        reject(new Error('FileReader failed'));
      };

      reader.readAsDataURL(file);
    });
  }, [useWebWorker]);

  return {
    convertImage: convert,
    progress,
    error,
  };
}
