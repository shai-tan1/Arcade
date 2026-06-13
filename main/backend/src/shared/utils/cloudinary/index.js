// src/shared/utils/cloudinary/index.js
import { v2 as cloudinary } from 'cloudinary';

let configured = false;

// True when Cloudinary credentials are present in the environment.
export function cloudinaryEnabled() {
  return Boolean(
    process.env.CLOUDINARY_URL ||
    (process.env.CLOUDINARY_CLOUD_NAME &&
      process.env.CLOUDINARY_API_KEY &&
      process.env.CLOUDINARY_API_SECRET)
  );
}

function ensureConfig() {
  if (configured) return;
  if (process.env.CLOUDINARY_CLOUD_NAME) {
    cloudinary.config({
      cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
      api_key: process.env.CLOUDINARY_API_KEY,
      api_secret: process.env.CLOUDINARY_API_SECRET,
      secure: true,
    });
  } else {
    cloudinary.config({ secure: true }); // reads CLOUDINARY_URL
  }
  configured = true;
}

// Upload a processed image buffer; resolves to the Cloudinary result (incl. secure_url).
export function uploadBuffer(buffer, { folder, publicId }) {
  ensureConfig();
  return new Promise((resolve, reject) => {
    const stream = cloudinary.uploader.upload_stream(
      { folder, public_id: publicId, resource_type: 'image', overwrite: true },
      (error, result) => (error ? reject(error) : resolve(result))
    );
    stream.end(buffer);
  });
}
