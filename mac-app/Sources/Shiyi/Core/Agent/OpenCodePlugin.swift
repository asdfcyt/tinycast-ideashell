import Foundation

/// 装进 `~/.config/opencode/plugins/shiyi.js` 的 opencode 插件。opencode 没有 shell 钩子，只能用插件接入。
///
/// 和「结审」不冲突的关键：
/// - 结审用 `opencode serve --port 4196` 跑自己的审计 Agent。这个插件是全局的，会被每个 opencode 进程加载，
///   所以它一启动就看自己的端口——在拾忆的「只观察的端口」里（默认 4196，还会读 OPENCODE_PORT）就进入「只观察」：
///   只上报运行状态和一轮结束（验收卡只展示，不能追加指令），不拦截工具、不答复权限 / 提问，结审自己的逻辑不受影响。
/// - 子会话（task 派出的子 Agent）不单独弹验收卡、不单独算运行，只在父会话下显示正在做什么。
/// - 工具调用前先问拾忆；拾忆放行过的操作，紧跟着的 opencode 自己的权限询问会被自动应答，不会再弹第二张卡。
enum OpenCodePlugin {
    static let version = "v3"

    static let source = #"""
// shiyi-opencode-plugin v3
// 由「拾忆」自动安装和更新，请不要手改；在拾忆里关闭 opencode 接入时会自动删除。
import http from "node:http";
import { readFileSync } from "node:fs";

const BRIDGE_FILE = `${process.env.HOME}/Library/Application Support/Shiyi/agent-bridge.json`;

let bridgeCache = { at: 0, v: null };
function bridge() {
  const now = Date.now();
  if (now - bridgeCache.at < 2000) return bridgeCache.v;
  let v = null;
  try { v = JSON.parse(readFileSync(BRIDGE_FILE, "utf8")); } catch {}
  bridgeCache = { at: now, v };
  return v;
}

// 直连本机端口，绕开系统 / 环境变量里的代理
function post(body, waitMs) {
  const b = bridge();
  if (!b || !b.port || !b.token) return Promise.resolve(null);
  return new Promise((resolve) => {
    const data = JSON.stringify(body);
    const req = http.request({
      host: "127.0.0.1", port: b.port, path: "/v1/hook/opencode", method: "POST", timeout: waitMs,
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), "X-Shiyi-Token": b.token },
    }, (res) => {
      let buf = "";
      res.setEncoding("utf8");
      res.on("data", (c) => { buf += c; });
      res.on("end", () => { try { resolve(res.statusCode === 200 ? JSON.parse(buf) : null); } catch { resolve(null); } });
    });
    req.on("timeout", () => { req.destroy(); resolve(null); });
    req.on("error", () => resolve(null));
    req.end(data);
  });
}

const quick = 5000;
const long = () => ((bridge() && bridge().timeout) || 90) * 1000 + 15000;

export default async function ShiyiPlugin({ client, serverUrl }) {
  let port = 0;
  try { port = parseInt(new URL(serverUrl).port) || 0; } catch {}
  const internalFetch = client && client._client && client._client.getConfig && client._client.getConfig().fetch || null;

  // off = 拾忆没开；observe = 结审等「别人的」服务，只观察不干预；full = 你自己用的 opencode
  function mode() {
    const b = bridge();
    if (!b) return "off";
    if (!port) return "full";
    const list = (b.observePorts || []).map(Number);
    if (process.env.OPENCODE_PORT) list.push(Number(process.env.OPENCODE_PORT));
    return list.includes(port) ? "observe" : "full";
  }

  function api(path, init, dir) {
    const headers = { "Content-Type": "application/json" };
    if (dir) headers["x-opencode-directory"] = encodeURIComponent(dir);
    const url = new URL(path, serverUrl || "http://127.0.0.1:4096").toString();
    const opts = { ...(init || {}), headers };
    return internalFetch ? internalFetch(new Request(url, opts)) : fetch(url, opts);
  }

  const sessions = new Map();
  const abortedAt = new Map();
  const roles = new Map();
  const allowed = new Map();

  function S(sid) {
    if (!sessions.has(sid)) sessions.set(sid, { parent: null, dir: "", title: "", loaded: null, text: new Map(), order: [], busy: false, lastIdle: 0, failed: "" });
    return sessions.get(sid);
  }

  function ensure(sid) {
    const s = S(sid);
    if (!s.loaded) {
      s.loaded = (async () => {
        try {
          const r = await api(`/session/${sid}`);
          if (r.ok) {
            const j = await r.json();
            s.parent = j.parentID || null;
            if (j.directory) s.dir = j.directory;
            if (j.title) s.title = j.title;
          }
        } catch {}
      })();
    }
    return s.loaded.then(() => s);
  }

  async function root(sid) {
    let id = sid;
    let s = await ensure(id);
    for (let i = 0; s.parent && i < 6; i++) { id = s.parent; s = await ensure(id); }
    return { id, s, child: id !== sid };
  }

  const permName = (tool) => (["edit", "write", "patch", "multiedit", "apply_patch"].includes(tool) ? "edit" : tool);

  async function reply(path, body, dir) {
    try { await api(path, { method: "POST", body: JSON.stringify(body) }, dir); } catch {}
  }

  async function onBusy(sid) {
    const r = await root(sid);
    if (r.child) return;
    r.s.lastIdle = 0; // 新一轮开始了：之后的「结束」不再当作重复事件
    if (r.s.busy) return;
    r.s.busy = true;
    r.s.failed = "";
    post({ event: "busy", v: 3, pid: process.pid, session_id: r.id, cwd: r.s.dir, title: r.s.title, observe: mode() === "observe" }, quick);
  }

  async function onIdle(sid) {
    const r = await root(sid);
    if (r.child) return;
    const s = r.s;
    const now = Date.now();
    if (now - s.lastIdle < 1500) return;
    s.lastIdle = now;
    let text = "";
    for (let i = s.order.length - 1; i >= 0 && !text; i--) text = s.text.get(s.order[i]) || "";
    const failed = s.failed;
    const had = s.busy || text || failed;
    s.busy = false; s.text.clear(); s.order = []; s.failed = "";
    if (!had) return;
    const observe = mode() === "observe";
    const aborted = Date.now() - (abortedAt.get(r.id) || 0) < 20000;
    const res = await post({ event: "idle", v: 3, aborted, session_id: r.id, cwd: s.dir, title: s.title, observe, dispatch: !!process.env.SHIYI_DISPATCH, last_assistant_message: text || failed, failed: !!failed }, long());
    if (!observe && res && res.followup) {
      s.busy = true;
      await reply(`/session/${r.id}/prompt_async`, { parts: [{ type: "text", text: res.followup }] }, s.dir);
    }
  }

  async function onPermission(p) {
    const r = await root(p.sessionID);
    const key = `${p.sessionID}:${p.permission}`;
    // 拾忆刚放行过同类操作：opencode 自己的询问直接应答，不弹第二张卡
    if (allowed.has(key) && Date.now() - allowed.get(key) < 60000) {
      await reply(`/permission/${p.id}/reply`, { reply: "once" }, r.s.dir);
      return;
    }
    const res = await post({ event: "permission", session_id: r.id, cwd: r.s.dir, permission: p.permission, patterns: p.patterns || [], metadata: p.metadata || {} }, long());
    if (!res) return;
    if (res.decision === "allow") await reply(`/permission/${p.id}/reply`, { reply: "once" }, r.s.dir);
    else if (res.decision === "deny") await reply(`/permission/${p.id}/reply`, { reply: "reject", message: res.reason }, r.s.dir);
  }

  // 拾忆里点了「停止」：桥接文件里会列出要停的会话，只停这个进程里正在跑的、不是只观察的
  const stopTimer = setInterval(() => {
    try {
      if (mode() !== "full") return;
      const list = (bridge() && bridge().stop) || [];
      for (const sid of list) {
        const s = sessions.get(sid);
        if (!s || !s.busy || s.parent) continue;
        if (Date.now() - (abortedAt.get(sid) || 0) < 10000) continue;
        abortedAt.set(sid, Date.now());
        void reply(`/session/${sid}/abort`, {}, s.dir);
      }
    } catch {}
  }, 1000);
  if (stopTimer && stopTimer.unref) stopTimer.unref();

  return {
    event: async ({ event }) => {
      const m = mode();
      if (m === "off") return;
      const t = event.type;
      const p = event.properties || {};
      try {
        if ((t === "session.created" || t === "session.updated") && p.info) {
          const s = S(p.info.id);
          s.parent = p.info.parentID || null;
          if (p.info.directory) s.dir = p.info.directory;
          if (p.info.title) s.title = p.info.title;
          s.loaded = s.loaded || Promise.resolve();
        } else if (t === "session.deleted" && p.info) {
          sessions.delete(p.info.id);
        } else if (t === "message.updated" && p.info && p.info.id && p.info.sessionID) {
          roles.set(p.info.id, p.info.role);
          if (roles.size > 300) roles.delete(roles.keys().next().value);
          if (p.info.role === "assistant") {
            const s = S(p.info.sessionID);
            if (!s.order.includes(p.info.id)) s.order.push(p.info.id);
          }
        } else if (t === "message.part.updated" && p.part && p.part.type === "text" && p.part.messageID && p.part.sessionID) {
          const s = S(p.part.sessionID);
          s.text.set(p.part.messageID, p.part.text || "");
          if (s.text.size > 12) s.text.delete(s.text.keys().next().value);
        } else if (t === "session.error") {
          const sid = p.sessionID;
          if (sid && !(p.error && p.error.name === "MessageAbortedError")) {
            S(sid).failed = (p.error && p.error.data && p.error.data.message) || (p.error && p.error.name) || "出错了";
          }
        } else if (t === "session.status" && p.sessionID && p.status) {
          if (p.status.type === "busy") void onBusy(p.sessionID);
          else if (p.status.type === "idle") void onIdle(p.sessionID);
        } else if (t === "session.idle" && p.sessionID) {
          void onIdle(p.sessionID);
        } else if (t === "permission.asked" && p.id && p.sessionID && m === "full") {
          void onPermission(p);
        }
      } catch {}
    },

    "tool.execute.before": async (input, output) => {
      if (mode() !== "full") return;
      let res = null;
      try {
        const r = await root(input.sessionID);
        res = await post({ event: "pre", v: 3, pid: process.pid, session_id: r.id, cwd: r.s.dir, tool: input.tool, args: output.args || {} }, long());
      } catch {}
      if (!res) return;
      if (res.decision === "allow") allowed.set(`${input.sessionID}:${permName(input.tool)}`, Date.now());
      if (res.decision === "deny") throw new Error(res.reason || "用户在拾忆中拒绝了这次操作");
    },

    "tool.execute.after": async (input) => {
      if (mode() === "off") return;
      void (async () => {
        try {
          const r = await root(input.sessionID);
          post({ event: "post", v: 3, pid: process.pid, session_id: r.id, cwd: r.s.dir, title: r.s.title, observe: mode() === "observe", tool: input.tool, args: input.args || {} }, quick);
        } catch {}
      })();
    },
  };
}
"""#
}
