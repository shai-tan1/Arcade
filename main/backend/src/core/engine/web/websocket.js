// websocket.js
import { WebSocketServer, WebSocket } from 'ws';
import jwt from 'jsonwebtoken';
import { ObjectId } from 'mongodb';
import { getDB } from '../../../core/engine/db/connectDB.js';

import { JWT_SECRET_KEY } from '../../../shared/constants/index.js';

// get collection 'users'
const users = () => getDB().collection('users');

// Module-level reference to the running WebSocket server.
// Set inside initWebSocket() so controllers can push events to clients.
let wssInstance = null;

/**
 * Send a JSON payload to every open socket that belongs to a given user.
 * A user can have several tabs open, so all of their sockets receive it.
 * @param {string} userId
 * @param {object} data
 */
export function emitToUser(userId, data) {
  if (!wssInstance) return;
  const targetId = String(userId);
  const payload = JSON.stringify(data);
  wssInstance.clients.forEach((client) => {
    if (
      client.readyState === WebSocket.OPEN &&
      String(client.userId) === targetId
    ) {
      client.send(payload);
    }
  });
}

/**
 * Send a JSON payload to several users at once (deduplicated).
 * @param {Array<string>} userIds
 * @param {object} data
 */
export function emitToUsers(userIds = [], data) {
  if (!wssInstance) return;
  const unique = [...new Set(userIds.map(String))];
  unique.forEach((id) => emitToUser(id, data));
}

// helper function for ID conversion
const toObjectId = (id) => (id instanceof ObjectId ? id : new ObjectId(id));

export async function initWebSocket(server) {
  // Resetting the status (on isOnline: false) for all users when the server starts
  try {
    console.log('WebSocket: Resetting the status (on isOnline: false) for all users');
    // Add bypassDocumentValidation: true for bulk reset
    await users().updateMany(
      { 'status.isOnline': true },
      {
        $set: {
          'status.isOnline': false,
          'status.activeConnections': 0,
          'status.activeTabs': [],
        },
        $currentDate: { 'status.lastSeen': true }
      },
      { collation: { locale: 'en', strength: 2 }, bypassDocumentValidation: true }
    );
  } catch (error) {
    console.error('WebSocket: Error resetting status:', error);
  }
// /Resetting the status (on isOnline: false) for all users when the server starts

  const wss = new WebSocketServer({ server });
  wssInstance = wss;

  async function verifyToken(token) {
    try {
      const decoded = jwt.verify(token, JWT_SECRET_KEY);
      return decoded._id;
    } catch (err) {
      return null;
    }
  }

  /* -----------------------------------------------------------
  ## Status and Activity Functions
  ----------------------------------------------------------- */

  // Offline control by timeout/visibility (5 seconds)
  async function updateUserActivity(userId, tabId, token) {
    try {
      const userIdObject = toObjectId(userId);
      const verifiedUserId = await verifyToken(token);
      if (!verifiedUserId || verifiedUserId !== userId) return false;

      // 5 second timeout for throttling
      const fiveSecondsAgo = new Date(Date.now() - 5 * 1000);

      const user = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const userStatus = user?.status || {};
      const activeTabs = userStatus.activeTabs || [];

      // SPAM FIX 1: If there are no active tabs (after Logout/Heartbeat), ignore Ping.
      if (activeTabs.length === 0) {
        return true;
      }

      const currentTab = activeTabs.find(tab => tab.tabId === tabId);

      // offline logic by invisibility (heartbeat timeout)
      if (user && currentTab && !currentTab.isVisible) {
        if (user.status?.isOnline === true) {

          // Removing a tab and setting isOnline: false in one request
          // Add bypassDocumentValidation: true for a complex operation
          const result = await users().findOneAndUpdate(
            { _id: userIdObject, 'status.isOnline': true },
            {
              $set: { 'status.isOnline': false, 'status.activeConnections': 0 },
              $currentDate: { 'status.lastSeen': true },
              $pull: { 'status.activeTabs': { tabId } }
            },
            { returnDocument: 'after', bypassDocumentValidation: true }
          );

          if (result?.value?.status?.isOnline === false) {
            broadcast({ type: 'user:offline', userId });
            console.log(`WebSocket: Set isOnline: false (due to timeout/invisibility) for userId ${userId}, tabId ${tabId}`);
          } else {
            // If couldn't set it offline (it means it was already offline) - just delete the tab
            console.log(`WebSocket: Skipping the re-setting of isOnline: false for userId ${userId}, tabId ${tabId} (the status is already OFF).`);
            await users().updateOne(
              { _id: userIdObject },
              { $pull: { 'status.activeTabs': { tabId } } }
            );
          }
          return true;
        }
      }

      // 2. Throttling logic (updating lastSeen and broadcast 'online')
      if (user && currentTab) {
        const result = await users().findOneAndUpdate(
          {
            _id: userIdObject,
            $or: [{ 'status.lastSeen': { $lt: fiveSecondsAgo } }, { 'status.lastSeen': null }],
          },
          {
            $set: { 'status.isOnline': true },
            $currentDate: { 'status.lastSeen': true }
          },
          { returnDocument: 'after' }
        );

        if (result?.value) {
          broadcast({ type: 'user:online', userId });
          console.log(`WebSocket: Activity updated for userId ${userId} (Broadcast ON)`);
        }
      }
      return true;
    } catch (error) {
      console.error('WebSocket: Error updating activity:', error);
      return false;
    }
  }

  // Function to increase 'activeConnections' and add a tab (isOnline: true)
  async function incrementConnections(userId, tabId, token) {
    try {
      const userIdObject = toObjectId(userId);
      const verifiedUserId = await verifyToken(token);
      if (!verifiedUserId || verifiedUserId !== userId) return false;

      console.log(`WebSocket: Increase activeConnections for userId ${userId}, tabId ${tabId}`);

      const user = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const activeTabs = user?.status?.activeTabs || [];

      if (user && activeTabs.some((tab) => tab.tabId === tabId)) {
        // The tab exists: increase the counter and make it visible
        await users().findOneAndUpdate(
          { _id: userIdObject, 'status.activeTabs.tabId': tabId },
          {
            // we update isonline and lastseen if we become visible
            $set: { 'status.activeTabs.$[tab].isVisible': true, 'status.isOnline': true },
            $inc: { 'status.activeConnections': 1 },
            $currentDate: { 'status.lastSeen': true },
          },
          { returnDocument: 'after', arrayFilters: [{ 'tab.tabId': tabId }] }
        );
        broadcast({ type: 'user:online', userId });
      } else {
        // New tab: adding, increasing the counter
        await users().findOneAndUpdate(
          { _id: userIdObject },
          {
            $addToSet: { 'status.activeTabs': { tabId, isVisible: true } },
            $inc: { 'status.activeConnections': 1 },
            // Update isOnline and lastSeen when connecting again
            $set: { 'status.isOnline': true },
            $currentDate: { 'status.lastSeen': true },
          },
          { returnDocument: 'after' } // upsert: true removed
        );
        broadcast({ type: 'user:online', userId });
      }
      return true;
    } catch (error) {
      console.error('WebSocket: Error increasing activeConnections:', error);
      return false;
    }
  }

  // marks the tab as invisible without touching the counter
  async function markTabHidden(userId, tabId) {
    try {
      const userIdObject = toObjectId(userId);
      await users().updateOne(
        { _id: userIdObject, 'status.activeTabs.tabId': tabId },
        { $set: { 'status.activeTabs.$[tab].isVisible': false } },
        { arrayFilters: [{ 'tab.tabId': tabId }] }
      );
      console.log(`[HIDDEN] Tab ${tabId} for userId ${userId} marked as invisible.`);
    } catch (error) {
      console.error('WebSocket: Error when marking tab as hidden:', error);
    }
  }

  // decrementconnections function (exclusively for broken/closed/timeout)
  async function decrementConnections(userId, tabId, removeTab = false, isLogout = false, onComplete = () => { }) {
    const userIdObject = toObjectId(userId);
    console.log(`[DECREMENT] 1. Start for userId ${userId}, tabId ${tabId}, removeTab: ${removeTab}, isLogout: ${isLogout}`);

    try {
      if (isLogout) {
        // scenario 1: instant logout
        // Add bypassDocumentValidation: true for bulk reset
        await users().updateOne(
          { _id: userIdObject },
          {
            $set: { 'status.activeTabs': [], 'status.activeConnections': 0, 'status.isOnline': false },
            $currentDate: { 'status.lastSeen': true }
          },
          { bypassDocumentValidation: true }
        );
        broadcast({ type: 'user:offline', userId });
        console.log(`[DECREMENT] 2. SUCCESS: User ${userId} came out (Logout).`);
        return onComplete();
      }

      // Ignore if not closing/breaking
      if (!removeTab) {
        console.log(`[DECREMENT] We skip the operation. removeTab: false.`);
        return onComplete();
      }

      // 1. Read the current state to safely decrement the counter
      const userDocBeforePull = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const currentConnections = userDocBeforePull?.status?.activeConnections || 0;
      const newConnections = Math.max(0, currentConnections - 1); // never go into the minus

      // 2. Atomically remove the tab and install a new counter
      await users().updateOne(
        { _id: userIdObject },
        {
          $pull: { 'status.activeTabs': { tabId } },
          $set: { 'status.activeConnections': newConnections }, // Setting a safe value
          $currentDate: { 'status.lastSeen': true }
        },
        { bypassDocumentValidation: true } // Bypassing validation for complex $pull + $set operations
      );
      console.log(`[DECREMENT] 2. The tab is removed and activeConnections is set to ${newConnections}.`);


      // 3. Loading the current status for a final check of the activeTabs length
      const userDoc = await users().findOne(
        { _id: userIdObject },
        { projection: { 'status': 1 } }
      );

      const updatedStatus = userDoc?.status;
      // Use the actual length of the array, not just the activeConnections counter
      const activeTabsCount = updatedStatus?.activeTabs?.length || 0;
      console.log(`[DECREMENT] 3. Current activeTabs.length: ${activeTabsCount}`);


      // 4. final offline atomic check (only if array is empty)
      if (updatedStatus && updatedStatus.isOnline === true && activeTabsCount === 0) {
        const finalCheckResult = await users().updateOne(
          {
            _id: userIdObject,
            'status.isOnline': true,
            'status.activeTabs': { $size: 0 }, // Check that the array is empty
          },
          {
            $set: {
              'status.isOnline': false,
              'status.activeConnections': 0, // Synchronize the counter to 0
            },
            $currentDate: { 'status.lastSeen': true }
          }
        );

        if (finalCheckResult.modifiedCount > 0) {
          console.log(`[DECREMENT] 4. SUCCESS: OFFLINE TRIGGER (activeTabs=0) for userId ${userId}`);
          broadcast({ type: 'user:offline', userId });
        } else {
          console.log(`[DECREMENT] 4. Offline Check: Status remains TRUE or there are still tabs. modifiedCount=0`);
        }
      } else {
        console.log(`[DECREMENT] 4. Offline Check: User is online or has active tabs (${activeTabsCount}). Skipping the trigger.`);
      }

    } catch (error) {
      console.error('WebSocket: Error decreasing activeConnections:', error);
    }

    onComplete();
  }
  // /decrementconnections function (exclusively for broken/closed/timeout)

  /* -----------------------------------------------------------
  ## Connection management
  ----------------------------------------------------------- */

  wss.on('connection', (ws, req) => {
    console.log('WebSocket: Trying a new connection');
    const cookieHeader = req.headers.cookie;
    let token = null;
    if (cookieHeader) {
      const cookies = cookieHeader.split(';').reduce((acc, cookie) => {
        const [key, value] = cookie.trim().split('=');
        acc[key] = value;
        return acc;
      }, {});
      token = cookies.token;
    }

    if (!token) {
      ws.close(1008, 'Token not provided');
      return;
    }

    try {
      const decoded = jwt.verify(token, JWT_SECRET_KEY);
      ws.userId = decoded._id;
      ws.token = token;

      // Clearing old invisible tabs when connecting again
      cleanupOldTabs(ws.userId);

      ws.isAlive = true;
      ws.on('pong', async () => {
        ws.isAlive = true;
        if (ws.tabId) {
          // Processing Ping from the client
          await updateUserActivity(ws.userId, ws.tabId, ws.token);
        }
      });

      ws.on('message', async (message) => {
        try {
          const data = message.toString();
          if (data === 'ping') {
            ws.send('pong');
            return;
          }
          const parsed = JSON.parse(data);

          if (parsed.type === 'visibility' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            if (parsed.status === 'visible') {
              await incrementConnections(ws.userId, parsed.tabId, ws.token);
            } else if (parsed.status === 'hidden') {
              // Collapse: Just mark it as invisible without touching the counter
              await markTabHidden(ws.userId, parsed.tabId);
            }
          } else if (parsed.type === 'activity' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            await updateUserActivity(ws.userId, parsed.tabId, ws.token);
          } else if (parsed.type === 'logout' && ws.userId === parsed.userId) {
            ws.tabId = parsed.tabId;
            await decrementConnections(ws.userId, ws.tabId, true, true, () => {
              wss.clients.forEach((client) => {
                if (client !== ws && client.userId === ws.userId && client.readyState === WebSocket.OPEN) {
                  client.close(1000, 'The user has logged out');
                }
              });
              ws.close(1000, 'The user has logged out');
            });
          }
        } catch (error) {
          console.error('WebSocket: Error processing message:', error);
        }
      });

      ws.on('close', async () => {
        console.log(`WebSocket: The connection was closed. userId: ${ws.userId}, tabId: ${ws.tabId}`);
        if (ws.tabId) {
          // Connection lost (browser closed) -> delete tab
          await decrementConnections(ws.userId, ws.tabId, true);
        } else {
          console.log('WebSocket: Failed to determine tabId on close, decrementConnections operation skipped.');
        }
      });
    } catch (err) {
      ws.close(1008, 'Invalid token');
    }
  });

  // Checking client activity (Heartbeat)
  setInterval(() => {
    wss.clients.forEach(async (ws) => {
      if (!ws.isAlive && ws.tabId) {
        // If the client does not respond to ping (30 seconds), we consider it dead.
        console.log(`WebSocket: Heartbeat timeout for userId ${ws.userId}, tabId ${ws.tabId}.`);
        await decrementConnections(ws.userId, ws.tabId, true, false, () => {
          // Call ws.terminate() only after the MongoDB operation completes
          return ws.terminate();
        });
      }
      ws.isAlive = false;
      ws.ping();
    });
  }, 30000); // <-- heartbeat timeout 30 seconds

  function broadcast(data) {
    wss.clients.forEach((client) => {
      if (client.readyState === client.OPEN) {
        client.send(JSON.stringify(data));
      }
    });
  }

  // Clearing old tabs (at startup/upon connection)
  async function cleanupOldTabs(userId) {
    try {
      const userIdObject = toObjectId(userId);
      console.log(`WebSocket: Clearing old tabs for userId ${userId}`);

      // remove all invisible tabs and reset the activeConnections counter to 0.
      // added bypassdocumentvalidation: true
      const result = await users().findOneAndUpdate(
        { _id: userIdObject },
        {
          $pull: { 'status.activeTabs': { isVisible: false } },
          $set: { 'status.activeConnections': 0 },
          $currentDate: { 'status.lastSeen': true }
        },
        { returnDocument: 'after', bypassDocumentValidation: true } // upsert: true removed
      );

      if (result?.value) {
        const activeTabs = result.value.status?.activeTabs || [];
        console.log(`WebSocket: Cleared invisible tabs for userId ${userId}, activeTabs: ${activeTabs.length}`);
        // When cleaning, set it to offline if there are no visible tabs.
        if (!activeTabs.some((tab) => tab.isVisible)) {
          await users().updateOne(
            { _id: userIdObject },
            {
              $set: { 'status.isOnline': false },
              $currentDate: { 'status.lastSeen': true }
            },
            {}
          );
          console.log(`WebSocket: Set isOnline: false for userId ${userId} after clearing tabs`);
          broadcast({ type: 'user:offline', userId });
        }
      }
    } catch (error) {
      console.error('WebSocket: Error clearing old tabs:', error);
    }
  }

}
