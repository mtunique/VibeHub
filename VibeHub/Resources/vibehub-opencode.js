// Vibe Hub OpenCode plugin
// - Forwards OpenCode bus events to Vibe Hub's Unix socket.
// - Exposes a local control socket so Vibe Hub can send prompts without requiring an HTTP server.

import { connect, createServer } from "net";
import { existsSync, mkdirSync, readFileSync, unlinkSync } from "fs";
import os from "os";
import path from "path";

const DEFAULT_SOCKET = path.join(os.homedir(), ".vibehub", "ci.sock");
const VERSION = "1.0.2";

const ENV_KEYS = [
  "TERM_PROGRAM", "ITERM_SESSION_ID", "TERM_SESSION_ID",
  "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "__CFBundleIdentifier",
  "CONDUCTOR_WORKSPACE_NAME", "CONDUCTOR_PORT", "CURSOR_TRACE_ID",
  "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH",
];

function resolveSocketPath() {
  if (process.env.VIBEHUB_SOCKET_PATH) return process.env.VIBEHUB_SOCKET_PATH;
  for (const p of [
    // Sidecar next to the plugin file
    (() => { try {
      const selfPath = decodeURIComponent(new URL(import.meta.url).pathname);
      return path.join(path.dirname(selfPath), "vibehub.socket");
    } catch { return null; } })(),
    // Override written by installer
    path.join(os.homedir(), ".vibehub", "socket-path"),
  ]) {
    try { if (p && existsSync(p)) { const v = readFileSync(p, "utf8").trim(); if (v) return v; } } catch {}
  }
  return DEFAULT_SOCKET;
}

const SOCKET = resolveSocketPath();

// --- Socket helpers ---

function connectSocket(opts = {}) {
  return new Promise((resolve) => {
    const timeout = opts.timeout || 3000;
    try {
      const sock = connect({ path: SOCKET }, () => resolve(sock));
      sock.on("error", () => resolve(null));
      sock.setTimeout(timeout, () => { sock.destroy(); resolve(null); });
    } catch { resolve(null); }
  });
}

function sendToSocket(json) {
  return connectSocket().then((sock) => {
    if (!sock) return false;
    sock.write(JSON.stringify(json));
    sock.end();
    return true;
  });
}

function sendAndWaitResponse(json, timeoutMs = 300000) {
  return connectSocket({ timeout: timeoutMs }).then((sock) => {
    if (!sock) return null;
    sock.write(JSON.stringify(json));
    let buf = "";
    return new Promise((resolve) => {
      sock.on("data", (d) => { buf += d.toString(); });
      sock.on("end", () => { try { resolve(JSON.parse(buf)); } catch { resolve(null); } });
      sock.on("error", () => resolve(null));
    });
  });
}

// --- Utilities ---

function collectEnv() {
  const env = {};
  for (const k of ENV_KEYS) if (process.env[k]) env[k] = process.env[k];
  return env;
}

function titleCase(s) {
  return s ? s[0].toUpperCase() + s.slice(1) : "";
}

function safeOneLine(s) {
  return (s || "").toString().replace(/\n/g, " ").trim();
}

function detectTty() {
  try {
    const { execSync } = require("child_process");
    let walkPid = process.pid;
    for (let i = 0; i < 8; i++) {
      const info = execSync(`ps -o tty=,ppid= -p ${walkPid}`, { timeout: 1000 }).toString().trim();
      const [tty, ppid] = info.split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") return `/dev/${tty}`;
      if (!ppid || parseInt(ppid) <= 1) break;
      walkPid = parseInt(ppid);
    }
  } catch {}
  return null;
}

function parseUrlLike(value) {
  try {
    if (!value) return null;
    if (value instanceof URL) return value;
    const str = typeof value === "string" ? value
      : value.href || value.baseUrl || value.baseURL;
    return str ? new URL(str) : null;
  } catch { return null; }
}

function toolUseIdFromPart(part) {
  return part?.id || part?.toolUseID || part?.tool_use_id || part?.state?.id || null;
}

// --- Event dispatch table ---

const eventHandlers = {
  "session.created"(p, ctx) {
    const { id, directory: cwd = "" } = p.info;
    ctx.sessionCwd.set(id, cwd);
    ctx.getSession(id);
    ctx.setTabTitle(`opencode-${id}`, cwd, null, null);
    return ctx.base(`opencode-${id}`, { cwd, event: "SessionStart", status: "waiting_for_input" });
  },

  "session.deleted"(p, ctx) {
    ctx.sessions.delete(p.info.id);
    ctx.sessionCwd.delete(p.info.id);
    return ctx.base(`opencode-${p.info.id}`, { event: "SessionEnd", status: "ended", cwd: p.info.directory || "" });
  },

  "session.updated"(p, ctx) {
    const { id, directory, title } = p.info;
    if (directory) ctx.sessionCwd.set(id, directory);
    if (p.info.time?.archived) {
      ctx.sessions.delete(id);
      ctx.sessionCwd.delete(id);
      return ctx.base(`opencode-${id}`, { event: "SessionEnd", status: "ended", cwd: directory || "" });
    }
    if (title && !title.startsWith("New session")) {
      ctx.getSession(id).pendingTitle = title;
      ctx.setTabTitle(`opencode-${id}`, ctx.sessionCwd.get(id) || "", null, title);
    }
    return null;
  },

  "session.status"(p, ctx) {
    const rawId = ctx.resolveSessionId(p.sessionID || p.sessionId);
    ctx.getSession(rawId).lastActivityAt = Date.now();
    if (p.status?.type !== "idle") return null;
    const s = ctx.getSession(rawId);
    const cwd = ctx.sessionCwd.get(rawId) || "";
    const extra = { event: "Stop", status: "waiting_for_input", cwd, last_assistant_message: s.lastAssistantText || undefined };
    if (s.pendingTitle) { extra.session_title = s.pendingTitle; s.pendingTitle = null; }
    return ctx.base(`opencode-${rawId}`, extra);
  },

  "message.updated"(p, ctx) {
    const resolved = ctx.resolveSessionId(p.info.sessionID);
    ctx.msgRoles.set(p.info.id, { role: p.info.role, sessionID: resolved });
    if (ctx.msgRoles.size > 200) ctx.msgRoles.delete(ctx.msgRoles.keys().next().value);
    return null;
  },

  "message.part.updated"(p, ctx) {
    const part = p.part;
    if (part?.type === "text") return handleTextPart(part, ctx);
    if (part?.type === "tool") return handleToolPart(part, ctx);
    return null;
  },

  "permission.asked"(p, ctx) {
    const rawId = ctx.resolveSessionId(p.sessionID);
    ctx.getSession(rawId).lastActivityAt = Date.now();
    const toolName = titleCase(p.permission || "Tool");
    const patterns = p.patterns || [];
    const toolInput = { patterns, metadata: p.metadata };
    if (p.permission === "bash" && patterns.length) toolInput.command = patterns.join(" && ");
    if ((p.permission === "edit" || p.permission === "write") && patterns.length) toolInput.file_path = patterns[0];

    const sid = `opencode-${rawId}`;
    const cwd = ctx.sessionCwd.get(rawId) || "";
    return {
      _kind: "permission",
      pre: ctx.base(sid, { event: "PreToolUse", status: "running_tool", cwd, tool: toolName, tool_input: toolInput, tool_use_id: p.id }),
      permission: ctx.base(sid, { event: "PermissionRequest", status: "waiting_for_approval", cwd, tool: toolName, tool_input: toolInput, tool_use_id: p.id, _opencode_request_id: p.id }),
    };
  },

  "permission.replied"(p, ctx) {
    const rawId = ctx.resolveSessionId(p.sessionID);
    ctx.getSession(rawId).lastActivityAt = Date.now();
    return ctx.base(`opencode-${rawId}`, { event: "PostToolUse", status: "processing", cwd: ctx.sessionCwd.get(rawId) || "", tool_use_id: p.id });
  },

  "question.asked"(p, ctx) {
    const rawId = ctx.resolveSessionId(p.sessionID);
    ctx.getSession(rawId).lastActivityAt = Date.now();
    const questions = (p.questions || []).map((q) => ({
      question: q.question || "", header: q.header || "",
      options: (q.options || []).map((o) => ({ label: o.label, description: o.description })),
      multiSelect: !!q.multiple,
    }));
    return {
      _kind: "question",
      requestId: p.id,
      event: ctx.base(`opencode-${rawId}`, { event: "PermissionRequest", status: "waiting_for_approval", cwd: ctx.sessionCwd.get(rawId) || "", tool: "AskUserQuestion", tool_input: { questions }, tool_use_id: p.id }),
    };
  },

  "question.replied"(p, ctx) { return questionDone(p, ctx); },
  "question.rejected"(p, ctx) { return questionDone(p, ctx); },
};

function questionDone(p, ctx) {
  const rawId = ctx.resolveSessionId(p.sessionID);
  ctx.getSession(rawId).lastActivityAt = Date.now();
  return ctx.base(`opencode-${rawId}`, { event: "PostToolUse", status: "processing", cwd: ctx.sessionCwd.get(rawId) || "", tool: "AskUserQuestion", tool_use_id: p.id });
}

function handleTextPart(part, ctx) {
  const meta = ctx.msgRoles.get(part.messageID);
  if (!meta) return null;
  const text = part.text || "";
  if (!text) return null;
  const s = ctx.getSession(meta.sessionID);
  const cwd = ctx.sessionCwd.get(meta.sessionID) || "";
  const sid = `opencode-${meta.sessionID}`;

  if (meta.role === "user") {
    s.lastUserText = text;
    s.lastActivityAt = Date.now();
    ctx.setTabTitle(sid, cwd, text, null);
    return ctx.base(sid, { event: "UserPromptSubmit", status: "processing", cwd, prompt: text });
  }
  if (meta.role === "assistant") {
    s.lastAssistantText = text;
    s.lastActivityAt = Date.now();
    const now = Date.now();
    if (now - (s._lastAssistantEmitAt || 0) > 800) {
      s._lastAssistantEmitAt = now;
      return ctx.base(sid, { event: "AssistantMessage", status: "processing", cwd, last_assistant_message: text });
    }
  }
  return null;
}

function handleToolPart(part, ctx) {
  const rawId = ctx.resolveSessionId(part.sessionID);
  const sid = `opencode-${rawId}`;
  const cwd = ctx.sessionCwd.get(rawId) || "";
  const toolName = titleCase(part.tool || "Tool");
  const st = part.state?.status;
  const toolUseId = toolUseIdFromPart(part);

  if (st === "running" || st === "pending") {
    ctx.getSession(rawId).lastActivityAt = Date.now();
    return ctx.base(sid, { event: "PreToolUse", status: "running_tool", cwd, tool: toolName, tool_input: part.state?.input || {}, tool_use_id: toolUseId || undefined });
  }
  if (st === "completed" || st === "error") {
    ctx.getSession(rawId).lastActivityAt = Date.now();
    return ctx.base(sid, { event: "PostToolUse", status: "processing", cwd, tool: toolName, tool_input: part.state?.input || {}, tool_use_id: toolUseId || undefined });
  }
  return null;
}

// --- Approval / question reply helpers ---

const DECISION_MAP = { allow: "once", always: "always", deny: "reject" };

async function handleApprovalResponse(mapped, ctx) {
  if (!ctx.internalFetch) { await sendToSocket(mapped.permission); return; }

  await sendToSocket(mapped.pre);
  const response = await sendAndWaitResponse(mapped.permission);
  if (!response?.decision) return;

  const reply = DECISION_MAP[response.decision];
  const requestId = mapped.permission._opencode_request_id;
  if (!reply || !requestId) return;

  try {
    await ctx.internalFetch(new Request(`http://localhost:${ctx.serverPort}/permission/${requestId}/reply`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reply, message: response.reason }),
    }));
  } catch {}

  await sendToSocket(ctx.base(mapped.permission.session_id, {
    event: "PostToolUse", status: "processing", cwd: mapped.permission.cwd || "",
    tool: mapped.permission.tool, tool_input: mapped.permission.tool_input || {}, tool_use_id: requestId,
  }));
}

async function handleQuestionResponse(mapped, ctx) {
  if (!ctx.internalFetch) { await sendToSocket(mapped.event); return; }

  const response = await sendAndWaitResponse(mapped.event);
  if (!response || response.decision === "ask" || !Array.isArray(response.answers)) return;

  try {
    await ctx.internalFetch(new Request(`http://localhost:${ctx.serverPort}/question/${mapped.requestId}/reply`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ answers: response.answers }),
    }));
  } catch {}

  await sendToSocket(ctx.base(mapped.event.session_id, {
    event: "PostToolUse", status: "processing", cwd: mapped.event.cwd || "", tool: "AskUserQuestion", tool_use_id: mapped.requestId,
  }));
}

// --- Plugin export ---

export default {
  id: "vibehub",
  server: async ({ client }) => {
    const pid = process.pid;
    const clientConfig = client?._client?.getConfig?.() || null;

    const controlDir = path.join(os.homedir(), ".vibehub");
    try { mkdirSync(controlDir, { recursive: true }); } catch {}
    const CONTROL_SOCKET = path.join(controlDir, `ci-opencode-${pid}.sock`);

    const parsedServerUrl = parseUrlLike(clientConfig?.baseUrl) || parseUrlLike(clientConfig?.baseURL) || parseUrlLike(client?.serverUrl);
    const serverPort = parsedServerUrl ? parseInt(parsedServerUrl.port || "") || 4096 : 4096;
    const internalFetch = clientConfig?.fetch || null;
    const detectedTty = detectTty();

    // Terminal tab title via OSC 2 (Ghostty)
    const termProg = process.env.TERM_PROGRAM || "";
    const isOsc2Terminal = (termProg === "ghostty" || termProg === "xterm-ghostty") && !process.env.TMUX;
    let displayTitle = null;

    // Session state
    const msgRoles = new Map();
    const sessionCwd = new Map();
    const sessions = new Map();

    // Shared context passed to event handlers
    const ctx = {
      sessions, sessionCwd, msgRoles, internalFetch, serverPort,
      base(sessionId, extra) {
        return { session_id: sessionId, _source: "opencode", _ppid: pid, _env: collectEnv(), tty: detectedTty, _server_port: serverPort, _server_hostname: (parsedServerUrl?.hostname || "localhost"), ...extra };
      },
      getSession(rawId) {
        if (!sessions.has(rawId)) sessions.set(rawId, { lastUserText: "", lastAssistantText: "", pendingTitle: null, lastActivityAt: Date.now() });
        return sessions.get(rawId);
      },
      resolveSessionId(rawId) {
        if (sessions.has(rawId)) return rawId;
        if (sessions.size === 1) return sessions.keys().next().value;
        let best = null, bestTime = 0;
        for (const [id, s] of sessions) { if (s.lastActivityAt > bestTime) { bestTime = s.lastActivityAt; best = id; } }
        return best || rawId;
      },
      setTabTitle(sessionId, cwd, userText, aiTitle) {
        if (!isOsc2Terminal || !detectedTty) return;
        const project = (cwd || process.env.PWD || "session").split("/").pop() || "session";
        const prefix = sessionId.replace("opencode-", "").slice(0, 16);
        if (aiTitle) displayTitle = safeOneLine(aiTitle).slice(0, 30);
        else if (!displayTitle && userText) displayTitle = safeOneLine(userText).slice(0, 30);
        const title = displayTitle ? `${project} · ${displayTitle} · ${prefix}` : `${project} · ${prefix}`;
        try { require("fs").writeFileSync(detectedTty, `\x1b]2;${title}\x07`); } catch {}
      },
    };

    // --- Control socket server (for receiving prompts from Vibe Hub) ---

    function startControlServer() {
      try { if (existsSync(CONTROL_SOCKET)) unlinkSync(CONTROL_SOCKET); } catch {}

      const server = createServer((sock) => {
        let buf = "";
        sock.on("data", (d) => { buf += d.toString(); });
        sock.on("end", async () => {
          try {
            const req = JSON.parse(buf || "{}");
            if (req?.type !== "prompt" || !req.session_id || typeof req.text !== "string") {
              sock.write(JSON.stringify({ ok: false, error: "bad request" })); sock.end(); return;
            }
            const result = await tryPromptSession(req.session_id, req.text);
            sock.write(JSON.stringify(result)); sock.end();
          } catch {
            try { sock.write(JSON.stringify({ ok: false, error: "invalid json" })); sock.end(); } catch {}
          }
        });
        sock.on("error", () => {});
      });
      server.on("error", () => {});
      server.listen(CONTROL_SOCKET);

      let exitHandled = false;
      function handleExit() {
        if (exitHandled) return;
        exitHandled = true;
        // Send SessionEnd for all active sessions synchronously
        const net = require("net");
        for (const [rawId] of sessions) {
          try {
            const payload = JSON.stringify(ctx.base(`opencode-${rawId}`, { event: "SessionEnd", status: "ended", cwd: sessionCwd.get(rawId) || "" }));
            const s = net.createConnection({ path: SOCKET }); s.write(payload); s.end();
          } catch {}
        }
        try { server.close(); } catch {}
        try { if (existsSync(CONTROL_SOCKET)) unlinkSync(CONTROL_SOCKET); } catch {}
      }

      process.on("exit", handleExit);
      process.on("SIGINT", () => { handleExit(); process.exit(0); });
      process.on("SIGTERM", () => { handleExit(); process.exit(0); });
    }

    async function tryPromptSession(sessionID, text) {
      const errors = [];
      // Strategy 1: SDK session prompt APIs
      for (const c of [
        { ctx: client?.session, fn: client?.session?.prompt },
        { ctx: client?.sessions, fn: client?.sessions?.prompt },
        { ctx: client?._client?.session, fn: client?._client?.session?.prompt },
        { ctx: client?._client?.sessions, fn: client?._client?.sessions?.prompt },
      ].filter((c) => typeof c.fn === "function")) {
        try {
          await c.fn.call(c.ctx || client, { path: { id: sessionID }, body: { parts: [{ type: "text", text }] } });
          return { ok: true, via: "session.prompt" };
        } catch (e) { errors.push(e?.message || String(e)); }
      }
      // Strategy 2: internal HTTP
      const fetcher = internalFetch || globalThis.fetch;
      if (fetcher && parsedServerUrl) {
        try {
          const resp = await fetcher(`${parsedServerUrl.origin}/session/${sessionID}/prompt_async`, {
            method: "POST", headers: { "content-type": "application/json" },
            body: JSON.stringify({ parts: [{ type: "text", text }] }),
          });
          if (resp?.status >= 200 && resp?.status < 300) return { ok: true, via: "http.prompt_async" };
          errors.push(`http ${resp?.status || "no response"}`);
        } catch (e) { errors.push(e?.message || String(e)); }
      }
      // Strategy 3: TUI prompt buffer
      if (client?.tui?.appendPrompt && client?.tui?.submitPrompt) {
        try {
          await client.tui.appendPrompt({ body: { text } });
          await client.tui.submitPrompt();
          return { ok: true, via: "tui.submitPrompt" };
        } catch (e) { errors.push(e?.message || String(e)); }
      }
      return { ok: false, error: errors[0] || "no client api" };
    }

    startControlServer();

    return {
      event: async ({ event }) => {
        const handler = eventHandlers[event.type];
        if (!handler) return;
        const mapped = handler(event.properties || {}, ctx);
        if (!mapped) return;
        if (mapped._kind === "permission") { await handleApprovalResponse(mapped, ctx); return; }
        if (mapped._kind === "question") { await handleQuestionResponse(mapped, ctx); return; }
        await sendToSocket(mapped);
      },
      "shell.env": async (_input, output) => {
        for (const v of ENV_KEYS) {
          if (process.env[v]) output.env["_CI_" + v] = process.env[v];
        }
      },
    };
  },
};
