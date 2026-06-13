// webpWorker.js — inline-воркер, будет вставлен в виде строки внутри useConvertToWebP

export const webpWorkerCode = () => {
  self.onmessage = async (e) => {
    const { file, options } = e.data;

    const {
      newFileName = 'converted.webp',
      targetSizeBytes = null,
      fallbackQuality = 0.6,
      maxWidthOrHeight = null,
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

      const canvas = new OffscreenCanvas(targetWidth, targetHeight);
      const ctx = canvas.getContext('2d');
      ctx.drawImage(imageBitmap, 0, 0, targetWidth, targetHeight);

      const createBlobWithQuality = async (quality) => {
        return await canvas.convertToBlob({ type: 'image/webp', quality });
      };

      let resultBlob;

      if (!targetSizeBytes) {
        resultBlob = await createBlobWithQuality(1);
      } else {
        let minQ = 0.3;
        let maxQ = 1;
        let bestBlob = null;

        for (let i = 0; i < 7; i++) {
          const mid = (minQ + maxQ) / 2;
          const blob = await createBlobWithQuality(mid);
          if (Math.abs(blob.size - targetSizeBytes) <= targetSizeBytes * 0.1) {
            bestBlob = blob;
            break;
          }
          if (blob.size > targetSizeBytes) {
            maxQ = mid;
          } else {
            bestBlob = blob;
            minQ = mid;
          }
        }

        resultBlob = bestBlob || (await createBlobWithQuality(fallbackQuality));
      }

      const newFile = new File([resultBlob], newFileName, {
        type: 'image/webp',
        lastModified: Date.now(),
      });

      self.postMessage({ file: newFile });
    } catch (error) {
      self.postMessage({ error: error.message });
    }
  };
};
