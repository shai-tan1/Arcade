// sharp-upload.js
import fs from "fs";
import path from "path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import Busboy from "busboy";
import { cloudinaryEnabled, uploadBuffer } from "../cloudinary/index.js";

// check if a file is a valid GIF
function isValidGif(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 6) return false;
  const header = buffer.toString("ascii", 0, 6);
  return header === "GIF87a" || header === "GIF89a";
}

// checking WebP signature
function isValidWebP(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return false;
  const riffHeader = buffer.toString("ascii", 0, 4) === "RIFF";
  const webpHeader = buffer.toString("ascii", 8, 12) === "WEBP";
  const chunkType = ["VP8 ", "VP8L", "VP8X"].includes(buffer.toString("ascii", 12, 16));
  console.log("checking WebP:", { riffHeader, webpHeader, chunkType, header: buffer.toString("ascii", 0, 16) });
  return riffHeader && webpHeader && chunkType;
}

// check for complex disguise
function hasSuspiciousContent(buffer, metadata) {
  if (!Buffer.isBuffer(buffer) || !metadata.width || !metadata.height) return true;
  const peSignature = buffer.length >= 2 && buffer.toString("ascii", 0, 2) === "MZ";
  return peSignature;
}

// directory mapping
const directoryMap = {
  userId: "uploads/users/images",
  postId: "uploads/posts/images",
};

// semaphore to limit simultaneous processing on the server
class Semaphore {
  constructor(max) {
    this.max = max;
    this.count = 0;
    this.waiting = [];
  }

  async acquire() {
    if (this.count < this.max) {
      this.count++;
      console.log(`Acquired processing slot, count: ${this.count}`);
      return;
    }
    console.log(`Waiting for processing slot, count: ${this.count}`);
    await new Promise(resolve => this.waiting.push(resolve));
  }

  release() {
    if (this.waiting.length > 0) {
      this.waiting.shift()();
    } else {
      this.count--;
    }
    console.log(`Released processing slot, count: ${this.count}`);
  }
}

const processSemaphore = new Semaphore(50); // limit 50 simultaneous processing

// storage for counting requests by IP
const ipRequestCounts = new Map();
const MAX_REQUESTS_PER_MINUTE = 50; // maximum 50 requests from one IP per minute
const WINDOW_MS = 60000; // 1 minute window

// cleaning up obsolete records
setInterval(() => {
  const now = Date.now();
  for (const [ip, { count, timestamp }] of ipRequestCounts) {
    if (now - timestamp > WINDOW_MS) {
      ipRequestCounts.delete(ip);
    }
  }
}, 10000); // checking every 10 seconds

// check for suspicious activity by IP
function isSuspiciousRequest(req) {
  const ip = req.ip || req.headers['x-forwarded-for'] || req.connection.remoteAddress;
  console.log(ip);
  const now = Date.now();

  if (!ipRequestCounts.has(ip)) {
    ipRequestCounts.set(ip, { count: 1, timestamp: now });
    return false;
  }

  const entry = ipRequestCounts.get(ip);
  if (now - entry.timestamp > WINDOW_MS) {
    entry.count = 1;
    entry.timestamp = now;
  } else {
    entry.count++;
    if (entry.count > MAX_REQUESTS_PER_MINUTE) {
      console.log(`IP ${ip} exceeded ${MAX_REQUESTS_PER_MINUTE} requests in 1 minute`);
      return true;
    }
  }

  return false;
}

export async function processImage(req, res, next) {
  // checking for suspicious activity
  if (isSuspiciousRequest(req)) {
    return res.status(429).json({ error: "Too many requests from this IP. Try again later." });
  }

  // waiting for an available slot to process
  await processSemaphore.acquire();
  try {
    if (!req.headers["content-type"]?.startsWith("multipart/form-data")) {
      processSemaphore.release();
      return res.status(400).json({ error: "Multipart/form-data required." });
    }

    // max file size
    const maxFileSize = 2621440; // 2.5 MB
    const busboy = Busboy({ headers: req.headers, limits: { fileSize: maxFileSize } });
    let fileBuffer = null;
    let fileName = null;
    let mimeType = null;
    let processingComplete = false;

    busboy.on("file", (fieldname, file, info) => {
      const { filename, mimeType: busboyMimeType } = info;
      console.log("Busboy file info:", { fieldname, filename, mimeType: busboyMimeType });

      if (fieldname !== "image") {
        file.resume();
        return;
      }

      const chunks = [];
      let totalSize = 0;

      file.on("data", (chunk) => {
        totalSize += chunk.length;
        if (totalSize > maxFileSize) {
          file.destroy();
          if (!processingComplete) {
            processingComplete = true;
            processSemaphore.release();
            res.status(400).json({ error: "File size exceeds 2.5 MB limit." });
          }
          return;
        }
        chunks.push(chunk);
      });

      file.on("end", () => {
        if (!processingComplete) {
          fileBuffer = Buffer.concat(chunks);
          fileName = filename || "unknown";
          mimeType = busboyMimeType || "application/octet-stream";
        }
      });

      file.on("limit", () => {
        console.log(`File ${filename} exceeded ${maxFileSize / 1024} KB limit`);
        if (!processingComplete) {
          processingComplete = true;
          processSemaphore.release();
          res.status(400).json({ error: "File size exceeds 2.5 MB limit." });
        }
      });
    });

    busboy.on("error", (err) => {
      console.error("Busboy error:", err);
      if (!processingComplete) {
        processingComplete = true;
        processSemaphore.release();
        res.status(400).json({ error: err.message });
      }
    });

    busboy.on("finish", async () => {
      if (processingComplete) return;
      try {
        console.log("Busboy finished:", { fileBufferLength: fileBuffer?.length, fileName, mimeType });

        if (!fileBuffer || fileBuffer.length === 0) {
          processSemaphore.release();
          return res.status(400).json({ error: "No file data received." });
        }

        const isImageExtension = /\.(jpe?g|png|webp|gif)$/i.test(fileName);
        const isImageMime = /^image\/(jpeg|png|webp|gif)$/.test(mimeType);
        console.log("Validation:", { isImageExtension, isImageMime, fileName, mimeType });

        if (!isImageExtension || !isImageMime) {
          if (fileName.toLowerCase().endsWith(".gif") && isValidGif(fileBuffer)) {
            mimeType = "image/gif";
          } else {

            // Logging rejected file attempts for security analysis ⬇️

            // fs.appendFileSync("upload_attempts.log", `${new Date().toISOString()} - Rejected: ${fileName}\n`);

            // /Logging rejected file attempts for security analysis ⬆️

            processSemaphore.release();
            return res.status(400).json({ error: "Only image files are allowed." });
          }
        }

        const paramKey = Object.keys(req.params).find((key) => directoryMap[key]);
        if (!paramKey || !directoryMap[paramKey]) {
          processSemaphore.release();
          return res.status(400).json({ error: "Invalid upload route." });
        }
        const directory = directoryMap[paramKey];

        const id = req.params.userId || req.params.postId;
        if (!id) {
          processSemaphore.release();
          return res.status(400).json({ error: "Missing ID parameter for filename generation." });
        }
        let processedFile;

        /*
        ---------------------------
        Image format normalization and sanitization
        ---------------------------
        */

        /*
        1. GIF file sanitization.
           If uploaded file is a GIF, validate its integrity and re-encode it safely.
           This prevents injection of malicious frames or broken animation data.
        */
        if (mimeType === "image/gif") {
          if (!isValidGif(fileBuffer)) {
            processSemaphore.release();
            return res.status(400).json({ error: "Invalid GIF file." });
          }
          const cleanedBuffer = await sharp(fileBuffer, { animated: true })
            .gif({ loop: 0, delay: null })
            .toBuffer()
            .catch((err) => {
              throw new Error("Failed to process GIF: " + err.message);
            });
          processedFile = {
            buffer: cleanedBuffer,
            mimetype: "image/gif",
            extension: "gif",
          };
          // /GIF file sanitization.

          /*
          2. WebP conversion and validation.
             For non-GIF images: convert input to optimized WebP format (quality=80)
             and validate resulting file header to ensure conversion integrity.
          */
        } else {
          const processedBuffer = await sharp(fileBuffer)
            .webp({ quality: 80 })
            .toBuffer()
            .catch((err) => {
              throw new Error("Failed to process image: " + err.message);
            });
          console.log("WebP header:", processedBuffer.toString("ascii", 0, 16));
          if (!isValidWebP(processedBuffer)) {
            processSemaphore.release();
            return res.status(400).json({ error: "Processed WebP file is invalid." });
          }
          processedFile = {
            buffer: processedBuffer,
            mimetype: "image/webp",
            extension: "webp",
          };
        }
        /*
        ---------------------------
        /Image format normalization and sanitization
        ---------------------------
        */

        /*
        ---------------------------
        Post-sanitization integrity and security checks
        ---------------------------
        This block performs final validation after Sharp has re-encoded the image.
        Ensures that the processed file is structurally valid, metadata-safe, 
        and free from any malicious signatures.
        */

        /*
        1. Validate basic image structure - ensure Sharp successfully extracted dimensions.
        If width/height are missing, file is not a valid image (possibly corrupted or fake).
         */
        const metadata = await sharp(processedFile.buffer).metadata();
        if (!metadata.width || !metadata.height) {
          processSemaphore.release();
          return res.status(400).json({ error: "Processed file is not a valid image." });
        }

        /*
        2. Check EXIF metadata size - reject files with abnormally large metadata blocks.
        This prevents potential injection or DoS attacks via oversized EXIF payloads (>1 MB).
        */
        if (metadata.exif && metadata.exif.length > 1024 * 1024) { // 1MB EXIF limit
          processSemaphore.release();
          return res.status(400).json({ error: "Suspiciously large metadata detected." });
        }

        /*
         3. Inspect binary content for malicious signatures (e.g., "MZ" header in PE files).
        Detects disguised executables or injected binary payloads.
         */
        if (hasSuspiciousContent(processedFile.buffer, metadata)) {
          processSemaphore.release();
          return res.status(400).json({ error: "Suspicious file content detected." });
        }
        /*
        ---------------------------
        /Post-sanitization integrity and security checks
        ---------------------------
        */

        const baseName = `${id}-${randomUUID()}`;
        const filename = `${baseName}.${processedFile.extension}`;

        if (cloudinaryEnabled()) {
          // Persistent storage (Render's disk is ephemeral).
          const result = await uploadBuffer(processedFile.buffer, {
            folder: directory,
            publicId: baseName,
          });
          req.processedFile = {
            filename,
            url: result.secure_url,
            publicId: result.public_id,
            mimetype: processedFile.mimetype,
            extension: processedFile.extension,
          };
        } else {
          // Local dev fallback: write to disk.
          const finalPath = path.join(directory, filename);
          fs.mkdirSync(directory, { recursive: true });
          fs.writeFileSync(finalPath, processedFile.buffer);
          req.processedFile = {
            filename,
            path: finalPath,
            mimetype: processedFile.mimetype,
            extension: processedFile.extension,
          };
        }

        processingComplete = true;
        processSemaphore.release();
        next();
      } catch (err) {
        console.error("Processing error:", err);
        if (!processingComplete) {
          processingComplete = true;
          processSemaphore.release();
          res.status(400).json({ error: err.message });
        }
      }
    });

    req.pipe(busboy);
  } catch (err) {
    console.error("Initial error:", err);
    processSemaphore.release();
    res.status(400).json({ error: err.message });
  }
}

// error handler
export const errors = (err, req, res, next) => {
  if (
    /.*(Multipart|File size|Invalid upload|Only image|Missing ID|Invalid GIF|Processed WebP file is invalid|Failed to process|No file data|Processed file is not a valid image|Suspicious file content detected|Too many requests).*/.test(
      err?.message
    )
  ) {
    return res.status(400).json({ error: err.message });
  }
  next(err);
};

// exception handling
process.on("uncaughtException", (err) => {
  console.error("Uncaught Exception:", err);
  process.exit(1);
});