// src/index.js
// BalatroSync Cloudflare Worker Backend (D1 SQLite + KV + Memory Fallback)
// High-performance, low-latency sync server for Balatro saves with session locking and atomic state.

const memoryStorage = new Map();

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, PUT, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Auth-Token",
    },
  });
}

function verifyAuth(request, env) {
  const expectedToken = env.AUTH_TOKEN || "DEFAULT_BALATRO_TOKEN";
  const authHeader = request.headers.get("Authorization") || "";
  const customHeader = request.headers.get("X-Auth-Token") || "";

  let token = "";
  if (authHeader.startsWith("Bearer ")) {
    token = authHeader.substring(7).trim();
  } else if (customHeader) {
    token = customHeader.trim();
  }

  return token === expectedToken;
}

// Storage abstraction (Priority 1: D1 SQLite database, Priority 2: KV, Priority 3: Memory)
async function getStorageItem(env, key) {
  if (env.balatro_db) {
    try {
      const row = await env.balatro_db
        .prepare("SELECT value FROM kv_store WHERE key = ?")
        .bind(key)
        .first();
      return row && row.value ? JSON.parse(row.value) : null;
    } catch (e) {
      console.error("D1 get error:", e);
    }
  }

  if (env.BALATRO_KV) {
    try {
      return await env.BALATRO_KV.get(key, "json");
    } catch (e) {}
  }

  const item = memoryStorage.get(key);
  return item ? JSON.parse(JSON.stringify(item)) : null;
}

async function setStorageItem(env, key, value) {
  if (env.balatro_db) {
    try {
      const now = Math.floor(Date.now() / 1000);
      const valStr = JSON.stringify(value);
      await env.balatro_db
        .prepare(
          "INSERT INTO kv_store (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at"
        )
        .bind(key, valStr, now)
        .run();
      return;
    } catch (e) {
      console.error("D1 set error:", e);
    }
  }

  if (env.BALATRO_KV) {
    try {
      await env.BALATRO_KV.put(key, JSON.stringify(value));
      return;
    } catch (e) {}
  }

  memoryStorage.set(key, JSON.parse(JSON.stringify(value)));
}

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const method = request.method.toUpperCase();

      // Handle CORS preflight
      if (method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, PUT, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Auth-Token",
          },
        });
      }

      // Health check (no auth required)
      if (url.pathname === "/" || url.pathname === "/health") {
        return jsonResponse({
          status: "ok",
          service: "BalatroSync Cloudflare Worker",
          version: "1.0.0",
          storage: env.balatro_db ? "Cloudflare D1 (SQLite)" : env.BALATRO_KV ? "Cloudflare KV" : "In-Memory",
        });
      }

      // Authenticate all API requests
      if (!verifyAuth(request, env)) {
        return jsonResponse({ error: "Unauthorized: Invalid or missing bearer token" }, 401);
      }

      // Route: /profile/:id/status
      const statusMatch = url.pathname.match(/^\/profile\/(\d+)\/status\/?$/);
      if (statusMatch && method === "GET") {
        const profileId = statusMatch[1];
        const sessionKey = `session_${profileId}`;
        const saveKey = `profile_${profileId}`;

        const session = (await getStorageItem(env, sessionKey)) || { device_id: null, last_seen: 0 };
        const save = await getStorageItem(env, saveKey);

        return jsonResponse({
          profile_id: parseInt(profileId, 10),
          timestamp: save ? save.timestamp || 0 : 0,
          is_active: save ? save.is_active : false,
          session: session,
        });
      }

      // Route: /profile/:id/session (Heartbeat)
      const sessionMatch = url.pathname.match(/^\/profile\/(\d+)\/session\/?$/);
      if (sessionMatch && method === "PUT") {
        const profileId = sessionMatch[1];
        const sessionKey = `session_${profileId}`;

        let body = {};
        try {
          body = await request.json();
        } catch (e) {
          return jsonResponse({ error: "Invalid JSON body" }, 400);
        }

        const sessionData = {
          device_id: body.device_id || "UNKNOWN",
          last_seen: Math.floor(Date.now() / 1000),
        };

        await setStorageItem(env, sessionKey, sessionData);
        return jsonResponse({ success: true, session: sessionData });
      }

      // Route: /profile/:id/takeover (Force Break Lock)
      const takeoverMatch = url.pathname.match(/^\/profile\/(\d+)\/takeover\/?$/);
      if (takeoverMatch && method === "POST") {
        const profileId = takeoverMatch[1];
        const sessionKey = `session_${profileId}`;

        let body = {};
        try {
          body = await request.json();
        } catch (e) {}

        const sessionData = {
          device_id: body.device_id || "TAKEOVER_DEVICE",
          last_seen: Math.floor(Date.now() / 1000),
        };

        await setStorageItem(env, sessionKey, sessionData);
        return jsonResponse({ success: true, message: "Session lock broken and claimed", session: sessionData });
      }

      // Route: /profile/:id (Save Payload Download / Upload)
      const profileMatch = url.pathname.match(/^\/profile\/(\d+)\/?$/);
      if (profileMatch) {
        const profileId = profileMatch[1];
        const saveKey = `profile_${profileId}`;
        const sessionKey = `session_${profileId}`;

        if (method === "GET") {
          const save = await getStorageItem(env, saveKey);
          if (!save) {
            return jsonResponse({ error: "Profile not found", profile_id: parseInt(profileId, 10) }, 404);
          }
          return jsonResponse(save);
        }

        if (method === "PUT") {
          let payload = {};
          try {
            payload = await request.json();
          } catch (e) {
            return jsonResponse({ error: "Invalid JSON payload" }, 400);
          }

          const isForce = url.searchParams.get("force") === "true";
          const currentSession = await getStorageItem(env, sessionKey);
          const now = Math.floor(Date.now() / 1000);

          // Session Lock Conflict Check
          if (!isForce && currentSession && currentSession.device_id) {
            if (currentSession.device_id !== payload.device_id) {
              const timeDiff = now - (currentSession.last_seen || 0);
              if (timeDiff < 180 && timeDiff >= 0) {
                return jsonResponse(
                  {
                    error: "SESSION_CONFLICT",
                    message: `Run is currently active on device '${currentSession.device_id}'`,
                    remote_device: currentSession.device_id,
                    last_seen: currentSession.last_seen,
                    time_diff: timeDiff,
                  },
                  409
                );
              }
            }
          }

          // Store Save
          payload.timestamp = now;
          await setStorageItem(env, saveKey, payload);

          // Update Heartbeat Session
          const updatedSession = {
            device_id: payload.device_id || "UNKNOWN",
            last_seen: now,
          };
          await setStorageItem(env, sessionKey, updatedSession);

          return jsonResponse({
            success: true,
            profile_id: parseInt(profileId, 10),
            timestamp: now,
            size: payload.size || 0,
          });
        }
      }

      return jsonResponse({ error: "Endpoint not found" }, 404);
    } catch (err) {
      return jsonResponse({ error: err.message, stack: err.stack }, 500);
    }
  },
};
