// frontend/src/shared/hooks/useWebSocket.js

import { useEffect, useRef, useState, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useAuthData } from '../../../features';
import { WS_URL } from '../../../shared/constants';

const generateTabId = () => {
  return (Date.now() + Math.random())
    .toString(36)
    .replace('.', '')
    .substring(2);
};

export function useWebSocket() {
  const queryClient = useQueryClient();
  const { authorizedUser, isSuccess: isAuthSuccess } = useAuthData();
  
  const wsRef = useRef(null);
  const tabIdRef = useRef(generateTabId());
  
  // Trigger for hard reset of connection
  const [reconnectCount, setReconnectCount] = useState(0);
  
  const hiddenTimeoutRef = useRef(null);
  
  // A flag to let you know if we've gone into "long sleep"
  const wasHiddenRef = useRef(false);

  const [wsState, setWsState] = useState({
    isConnected: false,
    isPending: false,
    isError: false,
    isSuccess: false,
  });

  const closeSocket = useCallback((socket, code, reason) => {
    if (socket) {
      socket.onclose = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onopen = null;
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close(code, reason);
      }
    }
  }, []);

  useEffect(() => {
    if (!isAuthSuccess || !authorizedUser?._id) {
      if (wsRef.current) {
        if (wsRef.current.readyState === WebSocket.OPEN) {
          wsRef.current.send(JSON.stringify({
            type: 'logout',
            userId: authorizedUser?._id || 'unknown',
            tabId: tabIdRef.current,
          }));
        }
        closeSocket(wsRef.current, 1000, 'User logged out');
        wsRef.current = null;
      }
      return;
    }

    // We generate a new ID for each new connection.
    tabIdRef.current = generateTabId();
    const currentTabId = tabIdRef.current;
    const userId = authorizedUser._id;

    setWsState(prev => ({ ...prev, isPending: true, isError: false }));

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState({ isConnected: true, isPending: false, isError: false, isSuccess: true });
      wasHiddenRef.current = false; // Reset the "was hidden" flag
      
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'visibility',
          status: 'visible', // Always visible on startup
          userId,
          tabId: currentTabId,
        }));
        ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
      }

      ws.activityInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
          ws.send('ping');
        }
      }, 30000); 
    };

    ws.onmessage = (event) => {
      try {
        if (event.data === 'pong') return;
        const data = JSON.parse(event.data);
        
        //  Change of status 'online', in real time (Optimistic update on socket event) 
        if (data.type === 'user:online' || data.type === 'user:offline') {
          const isOnlineNow = data.type === 'user:online';
          
          // 1. Instantly refresh the cache for THIS specific user
          // It doesn't matter whether we look at this user's profile or the list where he is.
          queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
             if (!oldData || !oldData.data) return oldData;
             
             // If the ID in the cache matches the ID from the socket event
             if (oldData.data._id === data.userId) {
               return {
                 ...oldData,
                 data: {
                   ...oldData.data,
                   status: {
                     ...oldData.data.status,
                     isOnline: isOnlineNow, // Set status instantly
                     // If you're logged in, update lastSeen to "now"
                     lastSeen: isOnlineNow ? new Date().toISOString() : oldData.data.status.lastSeen
                   }
                 }
               };
             }
             return oldData;
          });

          // 2. And only then do we start the background update (for reliability)
          queryClient.invalidateQueries({ queryKey: ['users'] });
        }

        // New direct message -> refresh conversations and the open thread
        if (data.type === 'message:new') {
          queryClient.invalidateQueries({ queryKey: ['messages'] });
        }

        // New community message -> refresh the affected room
        if (data.type === 'community:message') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }

        // Friend request / accept / change -> refresh friends + requests
        if (data.type === 'friend:update') {
          queryClient.invalidateQueries({ queryKey: ['friends'] });
        }

        // Community join request created / approved / declined
        if (data.type === 'community:request') {
          queryClient.invalidateQueries({ queryKey: ['communities'] });
        }

        // Games: matched / challenge / opponent progress / match over
        if (
          data.type === 'game:matched' ||
          data.type === 'game:challenge' ||
          data.type === 'game:update' ||
          data.type === 'game:over'
        ) {
          queryClient.invalidateQueries({ queryKey: ['games'] });
        }
      } catch (error) {
        console.error('[WS] Parse error:', error);
      }
    };

    ws.onclose = (event) => {
      setWsState(prev => ({ ...prev, isConnected: false, isSuccess: false }));
      if (ws.activityInterval) clearInterval(ws.activityInterval);

      // Auto-reconnect if the connection is lost
      if (ws === wsRef.current && isAuthSuccess) {
        setTimeout(() => {
             setReconnectCount(prev => prev + 1); 
        }, 1000);
      }
    };

    ws.onerror = (error) => {
      console.error('[WS] Error:', error);
      setWsState(prev => ({ ...prev, isError: true }));
      ws.close(); 
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        // 🟢 WE'RE BACK!

        // We immediately update the data from the server
        queryClient.invalidateQueries({ queryKey: ['users'] });

        // Optimistic Renewal of Ourselves (So that the light bulb immediately turns on in us)
        queryClient.setQueriesData({ queryKey: ['users'] }, (oldData) => {
           if (!oldData || !oldData.data) return oldData;
           if (oldData.data._id === userId) {
             return { ...oldData, data: { ...oldData.data, status: { ...oldData.data.status, isOnline: true } } };
           }
           return oldData;
        });

        if (hiddenTimeoutRef.current) {
          clearTimeout(hiddenTimeoutRef.current);
          hiddenTimeoutRef.current = null;
          wasHiddenRef.current = false;
          return; 
        }

        // Hard Reconnect After a Long Sleep
        if (wasHiddenRef.current || !ws || ws.readyState !== WebSocket.OPEN) {
           setReconnectCount(c => c + 1);
        } else {
           ws.send(JSON.stringify({ type: 'visibility', status: 'visible', userId, tabId: currentTabId }));
           ws.send(JSON.stringify({ type: 'activity', userId, tabId: currentTabId }));
        }

      } else {
         // 🔴 WE'RE LEAVING
         if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
         
         hiddenTimeoutRef.current = setTimeout(() => {
             wasHiddenRef.current = true; // Let's remember that we have "officially" gone into invisibility.
             if (ws.readyState === WebSocket.OPEN) {
                 ws.send(JSON.stringify({ type: 'visibility', status: 'hidden', userId, tabId: currentTabId }));
             }
             hiddenTimeoutRef.current = null;
         }, 4000); // exit (hidden) in 4 seconds
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);

    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      if (ws.activityInterval) clearInterval(ws.activityInterval);
      if (hiddenTimeoutRef.current) clearTimeout(hiddenTimeoutRef.current);
      closeSocket(ws, 1000, 'Cleanup/Reconnecting');
    };

  }, [isAuthSuccess, authorizedUser?._id, queryClient, reconnectCount, closeSocket]);

  return {
    isConnected: wsState.isConnected,
    isPending: wsState.isPending,
    isError: wsState.isError,
    isSuccess: wsState.isSuccess,
  };
}
