#!/usr/bin/env bash
# Deployment fixes for Vercel (frontend) + Render (backend) + MongoDB Atlas.
# Run from the repo "main/" directory:  bash apply-deploy-fix.sh
# Then commit & push so Render redeploys.
set -e
if [ ! -d backend/src ]; then echo "ERROR: run this from your repo's main/ directory (contains backend/ and frontend/)"; exit 1; fi

node <<'NODE'
const fs = require('fs');
function patch(file, edits) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [oldStr, newStr, label] of edits) {
    const count = s.split(oldStr).length - 1;
    if (count === 0) { console.log(`  - skip (already patched / not found): ${label}`); continue; }
    s = s.split(oldStr).join(newStr);
    console.log(`  + ${label} (${count}x)`);
  }
  fs.writeFileSync(file, s);
}

// 1) Mongo: use the Atlas connection string (MONGO_BASE_URI) whenever it is set.
patch('backend/src/core/engine/db/connectDB.js', [
[
`    const clientUri = PRODUCTION_STATUS
        ? \`mongodb://\${USER}:\${PASSWORD}@\${HOST}:\${PORT}/?authSource=\${AUTH_SOURCE}\`
        : BASE_URI;`,
`    const clientUri = BASE_URI
        ? BASE_URI
        : \`mongodb://\${USER}:\${PASSWORD}@\${HOST}:\${PORT}/?authSource=\${AUTH_SOURCE}\`;`,
'connectDB: prefer MONGO_BASE_URI (Atlas SRV)'
],
[
`    const mongoLogUri = PRODUCTION_STATUS
        ? \`\${HOST}:\${PORT}/\${DB_NAME}\`
        : \`\${BASE_URI}/\${DB_NAME}\`;`,
`    const mongoLogUri = BASE_URI
        ? DB_NAME
        : \`\${HOST}:\${PORT}/\${DB_NAME}\`;`,
'connectDB: do not log Atlas credentials'
],
]);

// 2) Auth cookie: SameSite=None so the cookie works across vercel.app <-> onrender.com.
patch('backend/src/modules/auth/auth.controller.js', [
[`sameSite: 'strict'`, `sameSite: 'none'`, "auth: login/register cookie SameSite=None"],
[`res.clearCookie('token', { httpOnly: true, secure: COOKIE_SECURE_STATUS });`,
 `res.clearCookie('token', { httpOnly: true, secure: COOKIE_SECURE_STATUS, sameSite: 'none' });`,
 "auth: logout cookie SameSite=None"],
]);

console.log('\nDone patching code.');
NODE

echo "Verifying syntax..."
node --check backend/src/core/engine/db/connectDB.js && echo "  OK connectDB.js"
node --check backend/src/modules/auth/auth.controller.js && echo "  OK auth.controller.js"
echo ""
echo "Next: git add -A && git commit -m 'fix: atlas uri + cross-site cookie' && git push"
