// Vibe Hub OpenCode plugin
// - Forwards OpenCode bus events to Vibe Hub's Unix socket.
// - Exposes a local control socket so Vibe Hub can send prompts without requiring an HTTP server.

import { connect, createServer } from "net";
import { existsSync, mkdirSync, readFileSync, unlinkSync } from "fs";
import os from "os";
import path from "path";

const DEFAULT_SOCKET = path.join(os.homedir(), ".vibehub", "ci.sock");

function resolveSocketPath() {
  if (process.env.CLAUDE_ISLAND_SOCKET_PATH) return process.env.CLAUDE_ISLAND_SOCKET_PATH;

  // Sidecar next to the plugin file (preferred for strict OpenCode configs).
  try {
    const selfUrl = new URL(import.meta.url);
    const selfPath = decodeURIComponent(selfUrl.pathname);
    const sidecar = path.join(path.dirname(selfPath), "vibehub.socket");
    if (existsSync(sidecar)) {
      const p = (readFileSync(sidecar, "utf8") || "").trim();
      if (p) return p;
    }
  } catch {
    // ignore
  }

  // Optional override written by the installer.
  try {
    const overridePath = path.join(os.homedir(), ".vibehub", "socket-path");
    if (existsSync(overridePath)) {
      const p = (readFileSync(overridePath, "utf8") || "").trim();
      if (p) return p;
    }
  } catch {
    // ignore
  }

  return DEFAULT_SOCKET;
}

const SOCKET = resolveSocketPath();

// Native SSH mode: Vibe Hub writes the reverse-TCP port to this file.
const TCP_PORT_FILE = "/tmp/vibehub.port";

function resolveConnectOpts() {
  try {
    if (existsSync(TCP_PORT_FILE)) {
      const port = parseInt(readFileSync(TCP_PORT_FILE, "utf8").trim(), 10);
      if (port > 0) return { host: "127.0.0.1", port };
    }
  } catch { /* ignore */ }
  return { path: SOCKET };
}

// Terminal environment sampling
const ENV_KEYS = [
  "TERM_PROGRAM",
  "ITERM_SESSION_ID",
  "TERM_SESSION_ID",
  "TMUX",
  "TMUX_PANE",
  "KITTY_WINDOW_ID",
  "__CFBundleIdentifier",
  "CONDUCTOR_WORKSPACE_NAME",
  "CONDUCTOR_PORT",
  "CURSOR_TRACE_ID",
  "CMUX_WORKSPACE_ID",
  "CMUX_SURFACE_ID",
  "CMUX_SOCKET_PATH",
];

function collectEnv() {
  const env = {};
  for (const k of ENV_KEYS) {
    if (process.env[k]) env[k] = process.env[k];
  }
  return env;
}

function sendToSocket(json) {
  return new Promise((resolve) => {
    try {
      const sock = connect(resolveConnectOpts(), () => {
        sock.write(JSON.stringify(json));
        sock.end();
        resolve(true);
      });
      sock.on("error", () => resolve(false));
      sock.setTimeout(3000, () => {
        sock.destroy();
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}

function sendAndWaitResponse(json, timeoutMs = 300000) {
  return new Promise((resolve) => {
    try {
      const sock = connect(resolveConnectOpts(), () => {
        sock.write(JSON.stringify(json));
      });
      let buf = "";
      sock.on("data", (data) => {
        buf += data.toString();
      });
      sock.on("end", () => {
        try {
          resolve(JSON.parse(buf));
        } catch {
          resolve(null);
        }
      });
      sock.on("error", () => resolve(null));
      sock.setTimeout(timeoutMs, () => {
        sock.destroy();
        resolve(null);
      });
    } catch {
      resolve(null);
    }
  });
}

function titleCase(s) {
  if (!s) return "";
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function detectTty() {
  try {
    const { execSync } = require("child_process");
    let walkPid = process.pid;
    for (let i = 0; i < 8; i++) {
      const info = execSync(`ps -o tty=,ppid= -p ${walkPid}`, { timeout: 1000 })
        .toString()
        .trim();
      const parts = info.split(/\s+/);
      const tty = parts[0];
      const ppid = parseInt(parts[1]);
      if (tty && tty !== "??" && tty !== "?") return `/dev/${tty}`;
      if (!ppid || ppid <= 1) break;
      walkPid = ppid;
    }
  } catch {}
  return null;
}

function safeOneLine(s) {
  return (s || "").toString().replace(/\n/g, " ").trim();
}

export default async ({ client, serverUrl }) => {
  const pid = process.pid;
  const clientConfig = client?._client?.getConfig?.() || null;

  const controlDir = path.join(os.homedir(), ".vibehub");
  try {
    mkdirSync(controlDir, { recursive: true });
  } catch {
    // ignore
  }
  const CONTROL_SOCKET = path.join(controlDir, `ci-opencode-${pid}.sock`);

  function startControlServer() {
    try {
      if (existsSync(CONTROL_SOCKET)) unlinkSync(CONTROL_SOCKET);
    } catch {
      // ignore
    }

    const server = createServer((sock) => {
      let buf = "";
      sock.on("data", (data) => {
        buf += data.toString();
      });
      sock.on("end", async () => {
        try {
          const req = JSON.parse(buf || "{}");
          if (req && req.type === "prompt" && req.session_id && typeof req.text === "string") {
            const sessionID = req.session_id;
            const text = req.text;

            function errToString(e) {
              try {
                if (!e) return "";
                if (typeof e === "string") return e;
                if (e.message) return e.message;
                return JSON.stringify(e);
              } catch {
                return String(e);
              }
            }

            const result = await (async () => {
              const errors = [];

              // Strategy 1: SDK session prompt APIs (multiple shapes across versions).
              const candidates = [
                { ctx: client?.session, fn: client?.session?.prompt },
                { ctx: client?.sessions, fn: client?.sessions?.prompt },
                { ctx: client?._client?.session, fn: client?._client?.session?.prompt },
                { ctx: client?._client?.sessions, fn: client?._client?.sessions?.prompt },
              ].filter((c) => typeof c.fn === "function");

              for (const c of candidates) {
                try {
                  await c.fn.call(c.ctx || client, {
                    path: { id: sessionID },
                    body: { parts: [{ type: "text", text }] },
                  });
                  return { ok: true, via: "session.prompt" };
                } catch (e) {
                  errors.push(errToString(e));
                }
              }

              // Strategy 2: internal HTTP (works even when external HTTP server isn't reachable).
              const fetcher = internalFetch || globalThis.fetch;
              if (fetcher && parsedServerUrl) {
                try {
                  const origin = parsedServerUrl.origin;
                  const url = `${origin}/session/${sessionID}/prompt_async`;
                  const resp = await fetcher(url, {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ parts: [{ type: "text", text }] }),
                  });
                  if (resp && (resp.status >= 200 && resp.status < 300)) {
                    return { ok: true, via: "http.prompt_async" };
                  }
                  errors.push(`http ${resp ? resp.status : "no response"}`);
                } catch (e) {
                  errors.push(errToString(e));
                }
              }

              // Strategy 3: drive the TUI prompt buffer.
              if (client?.tui?.appendPrompt && client?.tui?.submitPrompt) {
                try {
                  await client.tui.appendPrompt({ body: { text } });
                  await client.tui.submitPrompt();
                  return { ok: true, via: "tui.submitPrompt" };
                } catch (e) {
                  errors.push(errToString(e));
                }
              }

              return { ok: false, error: errors[0] || "no client api" };
            })();

            sock.write(JSON.stringify(result));
            sock.end();
            return;
          }

          sock.write(JSON.stringify({ ok: false, error: "bad request" }));
          sock.end();
        } catch {
          try {
            sock.write(JSON.stringify({ ok: false, error: "invalid json" }));
            sock.end();
          } catch {
            // ignore
          }
        }
      });
      sock.on("error", () => {});
    });

    server.on("error", () => {});
    server.listen(CONTROL_SOCKET, () => {});

    // Send SessionEnd for all active sessions on exit (synchronous - "exit" handler can't do async)
    function sendEndEventsSync() {
      try {
        const net = require("net");
        for (const [rawId] of sessions) {
          const sid = `opencode-${rawId}`;
          const cwd = sessionCwd.get(rawId) || "";
          const payload = JSON.stringify(base(sid, { event: "SessionEnd", status: "ended", cwd }));
          try {
            const sock = net.createConnection(resolveConnectOpts());
            sock.write(payload);
            sock.end();
          } catch { /* ignore */ }
        }
      } catch { /* ignore */ }
    }

    let exitHandled = false;
    function handleExit() {
      if (exitHandled) return;
      exitHandled = true;
      sendEndEventsSync();
      try { server.close(); } catch { /* ignore */ }
      try { if (existsSync(CONTROL_SOCKET)) unlinkSync(CONTROL_SOCKET); } catch { /* ignore */ }
    }

    process.on("exit", handleExit);
    process.on("SIGINT", () => { handleExit(); process.exit(0); });
    process.on("SIGTERM", () => { handleExit(); process.exit(0); });
  }

  startControlServer();
  function parseUrlLike(value) {
    try {
      if (!value) return null;
      if (value instanceof URL) return value;
      if (typeof value === "string") return new URL(value);
      // Some clients pass a URL-like object.
      if (typeof value === "object" && typeof value.href === "string") return new URL(value.href);
      // Some configs expose baseUrl as a string.
      if (typeof value === "object" && typeof value.baseUrl === "string") return new URL(value.baseUrl);
      if (typeof value === "object" && typeof value.baseURL === "string") return new URL(value.baseURL);
      return value;
    } catch {
      return null;
    }
  }

  // Prefer the SDK client's baseUrl (it is what the TUI actually uses).
  const parsedServerUrl =
    parseUrlLike(clientConfig?.baseUrl) ||
    parseUrlLike(clientConfig?.baseURL) ||
    parseUrlLike(serverUrl);

  const serverPort = parsedServerUrl ? parseInt(parsedServerUrl.port || "") || 4096 : 4096;
  const serverHostname = (parsedServerUrl && (parsedServerUrl.hostname || parsedServerUrl.host)) || "localhost";
  const internalFetch = client?._client?.getConfig?.()?.fetch || null;
  const detectedTty = detectTty();

  // Optional: set terminal tab title via OSC 2 (Ghostty)
  const termProg = process.env.TERM_PROGRAM || "";
  const isOsc2Terminal = (termProg === "ghostty" || termProg === "xterm-ghostty") && !process.env.TMUX;
  let displayTitle = null;

  function setTabTitle(sessionId, cwd, userText, aiTitle) {
    if (!isOsc2Terminal) return;
    if (!detectedTty) return;

    const project = (cwd || process.env.PWD || "session").split("/").pop() || "session";
    const prefix = sessionId.replace("opencode-", "").slice(0, 16);

    if (aiTitle) {
      displayTitle = safeOneLine(aiTitle).slice(0, 30);
    } else if (!displayTitle && userText) {
      displayTitle = safeOneLine(userText).slice(0, 30);
    }

    const title = displayTitle ? `${project} · ${displayTitle} · ${prefix}` : `${project} · ${prefix}`;
    const osc = `\x1b]2;${title}\x07`;

    try {
      const fs = require("fs");
      fs.writeFileSync(detectedTty, osc);
    } catch {
      // Ignore
    }
  }

  const msgRoles = new Map();
  const sessionCwd = new Map();
  const sessions = new Map();

  // OpenCode may use different ID properties across event types
  // (e.g. session.created uses info.id while session.status uses sessionID).
  // If they diverge, Vibe Hub would see two sessions for one logical session.
  // resolveSessionId maps an unknown ID back to the canonical one when possible.
  function resolveSessionId(rawId) {
    if (sessions.has(rawId)) return rawId;
    // Only auto-resolve when there is exactly one known session to avoid
    // mis-mapping in the (unlikely) multi-session-per-process scenario.
    if (sessions.size === 1) {
      return sessions.keys().next().value;
    }
    // Multiple sessions: pick the most recently active one as a best guess.
    let best = null;
    let bestTime = 0;
    for (const [id, s] of sessions) {
      if (s.lastActivityAt > bestTime) {
        bestTime = s.lastActivityAt;
        best = id;
      }
    }
    return best || rawId;
  }

  function getSession(rawSessionId) {
    if (!sessions.has(rawSessionId)) {
      sessions.set(rawSessionId, {
        lastUserText: "",
        lastAssistantText: "",
        pendingTitle: null,
        lastActivityAt: Date.now(),
      });
    }
    return sessions.get(rawSessionId);
  }

  function base(sessionId, extra) {
    return {
      session_id: sessionId,
      _source: "opencode",
      _ppid: pid,
      _env: collectEnv(),
      tty: detectedTty,
      _server_port: serverPort,
      _server_hostname: serverHostname,
      ...extra,
    };
  }

  function toolUseIdFromPart(part) {
    return part?.id || part?.toolUseID || part?.tool_use_id || part?.state?.id || null;
  }

  function mapEvent(ev) {
    const t = ev.type;
    const p = ev.properties || {};

    if (t === "session.created" && p.info) {
      const cwd = p.info.directory || "";
      sessionCwd.set(p.info.id, cwd);
      getSession(p.info.id);
      const sid = `opencode-${p.info.id}`;
      setTabTitle(sid, cwd, null, null);
      return base(sid, {
        cwd,
        event: "SessionStart",
        status: "waiting_for_input",
      });
    }

    if (t === "session.deleted" && p.info) {
      sessions.delete(p.info.id);
      sessionCwd.delete(p.info.id);
      return base(`opencode-${p.info.id}`, {
        event: "SessionEnd",
        status: "ended",
        cwd: p.info.directory || "",
      });
    }

    if (t === "session.updated" && p.info) {
      if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
      if (p.info.time?.archived) {
        sessions.delete(p.info.id);
        sessionCwd.delete(p.info.id);
        return base(`opencode-${p.info.id}`, {
          event: "SessionEnd",
          status: "ended",
          cwd: p.info.directory || "",
        });
      }
      if (p.info.title && !p.info.title.startsWith("New session")) {
        const s = getSession(p.info.id);
        s.pendingTitle = p.info.title;
        setTabTitle(`opencode-${p.info.id}`, sessionCwd.get(p.info.id) || "", null, p.info.title);
      }
      return null;
    }

    if (t === "session.status" && (p.sessionID || p.sessionId)) {
      const rawSessionId = resolveSessionId(p.sessionID || p.sessionId);
      getSession(rawSessionId).lastActivityAt = Date.now();
      if (p.status?.type === "idle") {
        const sid = `opencode-${rawSessionId}`;
        const cwd = sessionCwd.get(rawSessionId) || "";
        const s = getSession(rawSessionId);
        const extra = {
          event: "Stop",
          status: "waiting_for_input",
          cwd,
          last_assistant_message: s.lastAssistantText || undefined,
        };
        if (s.pendingTitle) {
          extra.codex_title = s.pendingTitle;
          s.pendingTitle = null;
        }
        return base(sid, extra);
      }
      return null;
    }

    if (t === "message.updated" && p.info?.id && p.info?.sessionID) {
      const resolvedSID = resolveSessionId(p.info.sessionID);
      msgRoles.set(p.info.id, { role: p.info.role, sessionID: resolvedSID });
      if (msgRoles.size > 200) {
        msgRoles.delete(msgRoles.keys().next().value);
      }
      return null;
    }

    if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
      const meta = msgRoles.get(p.part.messageID);
      if (!meta) return null;
      const s = getSession(meta.sessionID);
      const cwd = sessionCwd.get(meta.sessionID) || "";
      const text = p.part.text || "";
      if (meta.role === "user" && text) {
        s.lastUserText = text;
        s.lastActivityAt = Date.now();
        setTabTitle(`opencode-${meta.sessionID}`, cwd, text, null);
        return base(`opencode-${meta.sessionID}`, {
          event: "UserPromptSubmit",
          status: "processing",
          cwd,
          prompt: text,
        });
      }
      if (meta.role === "assistant" && text) {
        s.lastAssistantText = text;
        s.lastActivityAt = Date.now();
        // Throttle: only emit every ~800ms to keep chat view updated without flooding.
        const now = Date.now();
        if (now - (s._lastAssistantEmitAt || 0) > 800) {
          s._lastAssistantEmitAt = now;
          return base(`opencode-${meta.sessionID}`, {
            event: "AssistantMessage",
            status: "processing",
            cwd,
            last_assistant_message: text,
          });
        }
      }
      return null;
    }

    if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
      const resolvedToolSID = resolveSessionId(p.part.sessionID);
      const sid = `opencode-${resolvedToolSID}`;
      const cwd = sessionCwd.get(resolvedToolSID) || "";
      const toolName = titleCase(p.part.tool || "Tool");
      const st = p.part.state?.status;
      const toolUseId = toolUseIdFromPart(p.part);

      if (st === "running" || st === "pending") {
        getSession(resolvedToolSID).lastActivityAt = Date.now();
        return base(sid, {
          event: "PreToolUse",
          status: "running_tool",
          cwd,
          tool: toolName,
          tool_input: p.part.state?.input || {},
          tool_use_id: toolUseId || undefined,
        });
      }

      if (st === "completed" || st === "error") {
        getSession(resolvedToolSID).lastActivityAt = Date.now();
        return base(sid, {
          event: "PostToolUse",
          status: "processing",
          cwd,
          tool: toolName,
          tool_input: p.part.state?.input || {},
          tool_use_id: toolUseId || undefined,
        });
      }
      return null;
    }

    if (t === "permission.asked" && p.id && p.sessionID) {
      const resolvedPermSID = resolveSessionId(p.sessionID);
      getSession(resolvedPermSID).lastActivityAt = Date.now();
      const requestId = p.id;
      const toolName = titleCase(p.permission || "Tool");
      const patterns = p.patterns || [];
      const toolInput = { patterns, metadata: p.metadata };
      if (p.permission === "bash" && patterns.length > 0) toolInput.command = patterns.join(" && ");
      if ((p.permission === "edit" || p.permission === "write") && patterns.length > 0) toolInput.file_path = patterns[0];

      // We'll emit a PreToolUse placeholder (fire-and-forget), then hold the socket for PermissionRequest.
      const sid = `opencode-${resolvedPermSID}`;
      const cwd = sessionCwd.get(resolvedPermSID) || "";

      return {
        _kind: "permission",
        pre: base(sid, {
          event: "PreToolUse",
          status: "running_tool",
          cwd,
          tool: toolName,
          tool_input: toolInput,
          tool_use_id: requestId,
        }),
        permission: base(sid, {
          event: "PermissionRequest",
          status: "waiting_for_approval",
          cwd,
          tool: toolName,
          tool_input: toolInput,
          tool_use_id: requestId,
          _opencode_request_id: requestId,
        }),
      };
    }

    if (t === "permission.replied" && p.sessionID && p.id) {
      const resolvedReplySID = resolveSessionId(p.sessionID);
      getSession(resolvedReplySID).lastActivityAt = Date.now();
      const sid = `opencode-${resolvedReplySID}`;
      const cwd = sessionCwd.get(resolvedReplySID) || "";
      return base(sid, {
        event: "PostToolUse",
        status: "processing",
        cwd,
        tool_use_id: p.id,
      });
    }

    if (t === "question.asked" && p.id && p.sessionID) {
      const resolvedQSID = resolveSessionId(p.sessionID);
      getSession(resolvedQSID).lastActivityAt = Date.now();
      const sid = `opencode-${resolvedQSID}`;
      const cwd = sessionCwd.get(resolvedQSID) || "";
      const questions = (p.questions || []).map((q) => ({
        question: q.question || "",
        header: q.header || "",
        options: (q.options || []).map((o) => ({
          label: o.label,
          description: o.description,
        })),
        multiSelect: !!q.multiple,
      }));

      return {
        _kind: "question",
        requestId: p.id,
        event: base(sid, {
          event: "PermissionRequest",
          status: "waiting_for_approval",
          cwd,
          tool: "AskUserQuestion",
          tool_input: { questions },
          tool_use_id: p.id,
        }),
      };
    }

    if ((t === "question.replied" || t === "question.rejected") && p.sessionID && p.id) {
      const resolvedQRSID = resolveSessionId(p.sessionID);
      getSession(resolvedQRSID).lastActivityAt = Date.now();
      const sid = `opencode-${resolvedQRSID}`;
      const cwd = sessionCwd.get(resolvedQRSID) || "";
      return base(sid, {
        event: "PostToolUse",
        status: "processing",
        cwd,
        tool: "AskUserQuestion",
        tool_use_id: p.id,
      });
    }

    return null;
  }

  async function handlePermission(mapped) {
    // Ensure we have an in-process way to reply to OpenCode permissions.
    if (!internalFetch) {
      await sendToSocket(mapped.permission);
      return;
    }

    await sendToSocket(mapped.pre);
    const response = await sendAndWaitResponse(mapped.permission);
    if (!response) return;

    const decision = response.decision;
    const reason = response.reason;
    if (!decision) return;

    // Vibe Hub sends { decision: allow|deny|always|ask }.
    // OpenCode expects { reply: once|always|reject }.
    const reply =
      decision === "allow" ? "once" :
      decision === "always" ? "always" :
      decision === "deny" ? "reject" :
      null;
    if (!reply) return;

    const requestId = mapped.permission._opencode_request_id;
    if (!requestId) return;

    try {
      await internalFetch(
        new Request(`http://localhost:${serverPort}/permission/${requestId}/reply`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ reply, message: reason }),
        })
      );
    } catch {
      // Ignore
    }

    // Mark the permission placeholder as completed in Vibe Hub.
    await sendToSocket(
      base(mapped.permission.session_id, {
        event: "PostToolUse",
        status: "processing",
        cwd: mapped.permission.cwd || "",
        tool: mapped.permission.tool,
        tool_input: mapped.permission.tool_input || {},
        tool_use_id: requestId,
      })
    );
  }

  async function handleQuestion(mapped) {
    if (!internalFetch) {
      await sendToSocket(mapped.event);
      return;
    }

    const response = await sendAndWaitResponse(mapped.event);
    if (!response) return;

    const decision = response.decision;
    const answers = response.answers;
    if (decision === "ask" || !answers || !Array.isArray(answers)) {
      return;
    }

    try {
      await internalFetch(
        new Request(`http://localhost:${serverPort}/question/${mapped.requestId}/reply`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ answers }),
        })
      );
    } catch {
      // Ignore
    }

    await sendToSocket(
      base(mapped.event.session_id, {
        event: "PostToolUse",
        status: "processing",
        cwd: mapped.event.cwd || "",
        tool: "AskUserQuestion",
        tool_use_id: mapped.requestId,
      })
    );
  }

  return {
    event: async ({ event }) => {
      const mapped = mapEvent(event);
      if (!mapped) return;
      if (mapped._kind === "permission") {
        // Run in background so permission.replied events aren't blocked waiting for VibeHub's response.
        handlePermission(mapped).catch(() => {});
        return;
      }
      if (mapped._kind === "question") {
        // Same: don't block the event queue while waiting for VibeHub.
        handleQuestion(mapped).catch(() => {});
        return;
      }
      await sendToSocket(mapped);
    },
    "shell.env": async (_input, output) => {
      // Inject terminal-related context into spawned shells.
      for (const v of [
        "TERM_PROGRAM",
        "ITERM_SESSION_ID",
        "TERM_SESSION_ID",
        "TMUX",
        "TMUX_PANE",
        "KITTY_WINDOW_ID",
        "__CFBundleIdentifier",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_SOCKET_PATH",
      ]) {
        if (process.env[v]) output.env["_CI_" + v] = process.env[v];
      }
    },
  };
};
