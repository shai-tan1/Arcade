#!/usr/bin/env bash
# Switch image uploads (avatars, banners, post images) from local disk to Cloudinary,
# so media persists on Render's ephemeral filesystem. Local dev still falls back to disk.
# Run from the repo "main/" directory:  bash apply-cloudinary.sh
# Then: cd backend && npm install cloudinary   (or just commit & let Render run npm install)
set -e
if [ ! -d backend/src ] || [ ! -d frontend/src ]; then echo "ERROR: run from your repo's main/ directory"; exit 1; fi
if grep -q "cloudinary/index.js" backend/src/shared/utils/sharp/sharp-upload.js 2>/dev/null; then
  echo "Looks already applied (sharp-upload imports cloudinary). Skipping to avoid double-patching."; exit 0
fi

# 1) Cloudinary helper (new file)
mkdir -p backend/src/shared/utils/cloudinary
cat > backend/src/shared/utils/cloudinary/index.js << 'CLOUDEOF'
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
CLOUDEOF
echo "  + wrote backend/src/shared/utils/cloudinary/index.js"

# 2) In-place patches
node <<'NODE'
const fs = require('fs');
const path = require('path');

function patch(file, edits) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [oldStr, newStr, label] of edits) {
    const c = s.split(oldStr).length - 1;
    if (c === 0) { console.log('  - skip (not found): ' + label); continue; }
    s = s.split(oldStr).join(newStr);
    console.log('  + ' + label + ' (' + c + 'x)');
  }
  fs.writeFileSync(file, s);
}

patch('backend/src/shared/utils/sharp/sharp-upload.js', [
[`import Busboy from "busboy";`,
 `import Busboy from "busboy";\nimport { cloudinaryEnabled, uploadBuffer } from "../cloudinary/index.js";`,
 'sharp-upload: import cloudinary helper'],
[`        const filename = \`\${id}-\${randomUUID()}.\${processedFile.extension}\`;
        const finalPath = path.join(directory, filename);
        fs.mkdirSync(directory, { recursive: true });
        fs.writeFileSync(finalPath, processedFile.buffer);

        req.processedFile = {
          filename,
          path: finalPath,
          mimetype: processedFile.mimetype,
          extension: processedFile.extension,
        };`,
 `        const baseName = \`\${id}-\${randomUUID()}\`;
        const filename = \`\${baseName}.\${processedFile.extension}\`;

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
        }`,
 'sharp-upload: upload to Cloudinary when configured'],
]);

patch('backend/src/modules/post/posts.routes.js', [
[`imageUri: \`/uploads/posts/images/\${req.processedFile.filename}\`,`,
 `imageUri: req.processedFile.url || \`/uploads/posts/images/\${req.processedFile.filename}\`,`,
 'posts.routes: prefer Cloudinary url'],
]);

patch('backend/src/modules/user/users.routes.js', [
[`imageUri: \`/uploads/users/images/\${req.processedFile.filename}\`,`,
 `imageUri: req.processedFile.url || \`/uploads/users/images/\${req.processedFile.filename}\`,`,
 'users.routes: prefer Cloudinary url'],
]);

patch('backend/package.json', [
[`    "busboy": "^1.6.0",`,
 `    "busboy": "^1.6.0",\n    "cloudinary": "^2.5.1",`,
 'package.json: add cloudinary dependency'],
]);

// Frontend: make image src absolute-aware (.jsx only; never touches httpClient.js)
function walk(dir, acc) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) { if (name !== 'node_modules') walk(p, acc); }
    else if (name.endsWith('.jsx')) acc.push(p);
  }
  return acc;
}
const re = /API_BASE_URL \+ ([A-Za-z0-9_$?.\[\]'"]+)/g;
let total = 0, files = 0;
for (const f of walk('frontend/src', [])) {
  let s = fs.readFileSync(f, 'utf8');
  if (s.includes('/^https?:\\/\\//.test(')) continue; // already wrapped
  let n = 0;
  const out = s.replace(re, (m, p1) => { n++; return `(/^https?:\\/\\//.test(${p1}) ? ${p1} : API_BASE_URL + ${p1})`; });
  if (n > 0) { fs.writeFileSync(f, out); total += n; files++; console.log('  + frontend ' + f.replace('frontend/src/','') + ' (' + n + 'x)'); }
}
console.log('  frontend image URLs wrapped: ' + total + ' across ' + files + ' files');
console.log('\nDone patching.');
NODE

echo "Verifying backend syntax..."
for f in backend/src/shared/utils/cloudinary/index.js backend/src/shared/utils/sharp/sharp-upload.js backend/src/modules/post/posts.routes.js backend/src/modules/user/users.routes.js; do
  node --check "$f" && echo "  OK $f"
done
node -e "JSON.parse(require('fs').readFileSync('backend/package.json'))" && echo "  OK package.json"
echo ""
echo "Next: commit & push (Render runs npm install and picks up cloudinary), then add the 3 CLOUDINARY_* env vars on Render."
