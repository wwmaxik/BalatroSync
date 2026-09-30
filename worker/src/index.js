// src/index.js
// BalatroSync Cloudflare Worker Backend (D1 SQLite + Smart Script Serving)
// Serves install scripts directly via curl/irm and sync API for Balatro.

const memoryStorage = new Map();
const GITHUB_RAW_BASE = "https://raw.githubusercontent.com/wwmaxik/BalatroSync/main";

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

// Storage abstraction (D1 SQLite database with in-memory fallback)
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

async function fetchGithubFile(path) {
  try {
    const res = await fetch(`${GITHUB_RAW_BASE}/${path}`, {
      headers: { "User-Agent": "BalatroSync-Worker" },
      cf: { cacheTtl: 30, cacheEverything: true }
    });
    if (res.ok) {
      return await res.text();
    }
  } catch (e) {
    console.error(`Failed to fetch ${path} from GitHub:`, e);
  }
  return null;
}

function renderLandingHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>🃏 BalatroSync — Cloud Save Synchronization</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #11141a;
      color: #e4e7eb;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      padding: 20px;
    }
    .card {
      background: #1a1e27;
      border: 1px solid #2d3748;
      border-radius: 12px;
      max-width: 680px;
      width: 100%;
      padding: 32px;
      box-shadow: 0 12px 32px rgba(0,0,0,0.5);
    }
    h1 {
      font-size: 28px;
      margin-bottom: 8px;
      color: #f7fafc;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    p.sub {
      color: #94a3b8;
      font-size: 15px;
      margin-bottom: 24px;
    }
    .cmd-group {
      margin-bottom: 20px;
    }
    .cmd-title {
      font-size: 14px;
      font-weight: 600;
      color: #cbd5e1;
      margin-bottom: 6px;
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .cmd-box {
      background: #0d1117;
      border: 1px solid #30363d;
      border-radius: 8px;
      padding: 12px 14px;
      font-family: "JetBrains Mono", "Fira Code", monospace;
      font-size: 14px;
      color: #38bdf8;
      word-break: break-all;
      user-select: all;
    }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      background: #064e3b;
      color: #34d399;
      padding: 4px 10px;
      border-radius: 16px;
      font-size: 12px;
      font-weight: 600;
      margin-top: 12px;
    }
    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #34d399;
    }
    .links {
      margin-top: 24px;
      padding-top: 16px;
      border-top: 1px solid #2d3748;
      font-size: 13px;
      color: #64748b;
      display: flex;
      justify-content: space-between;
    }
    a { color: #38bdf8; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🃏 BalatroSync</h1>
    <p class="sub">Autonomous cross-platform cloud synchronization for Balatro via Cloudflare Workers.</p>

    <div class="cmd-group">
      <div class="cmd-title">🐧 Linux / Steam Deck (SteamOS) — 1-Line Install:</div>
      <div class="cmd-box">curl -sL balatro.wwmaxik.ru | bash</div>
    </div>

    <div class="cmd-group">
      <div class="cmd-title">🪟 Windows (PowerShell) — 1-Line Install:</div>
      <div class="cmd-box">irm balatro.wwmaxik.ru | iex</div>
    </div>

    <div>
      <span class="status"><span class="status-dot"></span> Cloudflare Worker Online (D1 Database)</span>
    </div>

    <div class="links">
      <span>Domain: balatro.wwmaxik.ru</span>
      <a href="https://github.com/wwmaxik/BalatroSync" target="_blank">GitHub Repository ➔</a>
    </div>
  </div>
</body>
</html>`;
}

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const method = request.method.toUpperCase();
      const ua = (request.headers.get("User-Agent") || "").toLowerCase();
      const accept = (request.headers.get("Accept") || "").toLowerCase();

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

      // =======================================================================
      // 1. One-Line Installer Routes (No Auth Required)
      // =======================================================================

      // Shell installer: /sh, /install.sh, /linux
      if (url.pathname === "/sh" || url.pathname === "/install.sh" || url.pathname === "/linux") {
        const script = await fetchGithubFile("install.sh");
        return new Response(script || "# Error: Failed to fetch install.sh from GitHub", {
          status: script ? 200 : 502,
          headers: {
            "Content-Type": "text/x-shellscript; charset=utf-8",
            "Cache-Control": "public, max-age=60",
          },
        });
      }

      // PowerShell installer: /ps1, /install.ps1, /win, /windows
      if (url.pathname === "/ps1" || url.pathname === "/install.ps1" || url.pathname === "/win" || url.pathname === "/windows") {
        const script = await fetchGithubFile("install.ps1");
        return new Response(script || "# Error: Failed to fetch install.ps1 from GitHub", {
          status: script ? 200 : 502,
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "public, max-age=60",
          },
        });
      }

      // Root path '/' smart handler
      if (url.pathname === "/" || url.pathname === "") {
        // If request originates from curl / wget / sh:
        if (ua.includes("curl") || ua.includes("wget") || ua.includes("httpie")) {
          const script = await fetchGithubFile("install.sh");
          return new Response(script || "# Error: Failed to fetch install.sh from GitHub", {
            status: script ? 200 : 502,
            headers: {
              "Content-Type": "text/x-shellscript; charset=utf-8",
              "Cache-Control": "public, max-age=60",
            },
          });
        }

        // If request originates from PowerShell:
        if (ua.includes("powershell")) {
          const script = await fetchGithubFile("install.ps1");
          return new Response(script || "# Error: Failed to fetch install.ps1 from GitHub", {
            status: script ? 200 : 502,
            headers: {
              "Content-Type": "text/plain; charset=utf-8",
              "Cache-Control": "public, max-age=60",
            },
          });
        }

        // If client requested JSON:
        if (accept.includes("application/json")) {
          return jsonResponse({
            status: "ok",
            service: "BalatroSync Cloudflare Worker",
            version: "1.2.0",
            domain: "balatro.wwmaxik.ru",
            storage: env.balatro_db ? "Cloudflare D1 (SQLite)" : env.BALATRO_KV ? "Cloudflare KV" : "In-Memory",
          });
        }

        // Default for browsers: landing page
        return new Response(renderLandingHtml(), {
          status: 200,
          headers: {
            "Content-Type": "text/html; charset=utf-8",
          },
        });
      }

      // Health check endpoint
      if (url.pathname === "/health") {
        return jsonResponse({
          status: "ok",
          service: "BalatroSync Cloudflare Worker",
          version: "1.2.0",
          domain: "balatro.wwmaxik.ru",
          storage: env.balatro_db ? "Cloudflare D1 (SQLite)" : env.BALATRO_KV ? "Cloudflare KV" : "In-Memory",
        });
      }

      // =======================================================================
      // 2. Authenticated Sync API Routes
      // =======================================================================

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
