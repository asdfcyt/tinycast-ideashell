import { LocalStorage } from "@raycast/api";
import { listTodos, TodoItem, updateTodos } from "./api";

/**
 * 滴答清单联动：通过官方 MCP（https://mcp.dida365.com，Bearer Token = 「API 口令」）。
 * - 带日期的待办 → 在滴答里创建任务并设置提醒（有时间：准点提醒；仅日期：当天 9:00 提醒）
 * - 在这边改内容 / 日期 → 同步更新滴答里的任务；这边完成 → 滴答里也完成
 * - 在滴答里完成的任务 → 同步时反向标记完成
 * 说明：闪念贝壳没有删除待办的接口，所以删除不会同步。
 *
 * 工具的参数名以服务端 tools/list 返回的 schema 为准（连接时保存一份），
 * 不依赖硬编码，尽量适应服务端的字段命名。
 */

const MCP_URL = "https://mcp.dida365.com";

const AUTH_KEY = "dida-auth-v1";
const TOOLS_KEY = "dida-tools-v1";
const MAP_KEY = "dida-map-v1";
const LAST_SYNC_KEY = "dida-last-sync-v1";
const LAST_ERROR_KEY = "dida-last-error-v1";

export interface Mapping {
  taskId: string;
  projectId?: string;
  sig: string;
  done?: boolean;
}

interface ToolDef {
  name: string;
  description?: string;
  inputSchema?: {
    properties?: Record<string, { type?: string; description?: string; enum?: unknown[] }>;
    required?: string[];
  };
}

export class DidaAuthError extends Error {}

// ── 授权 ──

export async function loadDidaToken(): Promise<string> {
  try {
    const raw = await LocalStorage.getItem<string>(AUTH_KEY);
    return raw ? ((JSON.parse(raw) as { token?: string }).token ?? "") : "";
  } catch {
    return "";
  }
}

export async function clearDida(): Promise<void> {
  await LocalStorage.removeItem(AUTH_KEY);
  await LocalStorage.removeItem(TOOLS_KEY);
  mcpSession = null;
  initPromise = null;
}

export async function isDidaConnected(): Promise<boolean> {
  return !!(await loadDidaToken());
}

export async function loadLastSync(): Promise<number> {
  return Number(await LocalStorage.getItem<string>(LAST_SYNC_KEY)) || 0;
}

export async function loadLastError(): Promise<string> {
  return (await LocalStorage.getItem<string>(LAST_ERROR_KEY)) ?? "";
}

// ── MCP 传输 ──

let rpcId = 0;
let mcpSession: string | null = null;
let initPromise: Promise<void> | null = null;

interface RpcResponse {
  result?: { content?: Array<{ type: string; text?: string }>; tools?: ToolDef[]; isError?: boolean };
  error?: { code: number; message: string };
}

async function rpc(token: string, body: Record<string, unknown>, withId = true): Promise<RpcResponse> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${token}`,
  };
  if (mcpSession) headers["Mcp-Session-Id"] = mcpSession;
  const res = await fetch(MCP_URL, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", ...(withId ? { id: ++rpcId } : {}), ...body }),
  });
  if (res.status === 401 || res.status === 403) {
    throw new DidaAuthError("滴答清单口令无效或已失效，请重新连接");
  }
  if (!res.ok) {
    const t = await res.text().catch(() => "");
    throw new Error(`滴答清单 MCP 错误（HTTP ${res.status}）${t.slice(0, 120)}`);
  }
  const sid = res.headers.get("mcp-session-id");
  if (sid) mcpSession = sid;
  if (!withId) return {};
  const text = await res.text();
  if (!text.trim()) return {};
  let payload = text;
  if ((res.headers.get("content-type") || "").includes("text/event-stream")) {
    payload = "";
    for (const line of text.split("\n")) if (line.startsWith("data:")) payload = line.slice(5).trim();
  }
  const data = JSON.parse(payload) as RpcResponse;
  if (data.error) throw new Error(`滴答清单 MCP：${data.error.message}`);
  return data;
}

function ensureInit(token: string): Promise<void> {
  if (!initPromise) {
    initPromise = (async () => {
      await rpc(token, {
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "tinycast-ideashell", version: "1.0.0" },
        },
      });
      await rpc(token, { method: "notifications/initialized" }, false).catch(() => undefined);
    })().catch((e) => {
      initPromise = null;
      throw e;
    });
  }
  return initPromise;
}

export async function callDida(name: string, args: Record<string, unknown>): Promise<string> {
  const token = await loadDidaToken();
  if (!token) throw new DidaAuthError("还没有连接滴答清单");
  await ensureInit(token);
  const r = await rpc(token, { method: "tools/call", params: { name, arguments: args } });
  const text = (r.result?.content ?? [])
    .filter((c) => c.type === "text" && c.text)
    .map((c) => c.text as string)
    .join("\n");
  if (r.result?.isError) throw new Error(`${name}：${text.slice(0, 200) || "调用失败"}`);
  return text;
}

/** 用「API 口令」连接：握手 → 拉取工具清单 → 检查需要的工具是否存在 */
export async function connectDida(token: string): Promise<{ missing: string[]; tools: number }> {
  const t = token.trim().replace(/^Bearer\s+/i, "");
  if (!t) throw new Error("请填写 API 口令");
  mcpSession = null;
  initPromise = null;
  await ensureInit(t);
  const r = await rpc(t, { method: "tools/list" });
  const tools = r.result?.tools ?? [];
  if (tools.length === 0) throw new Error("连不上滴答清单 MCP：没有取到工具清单");
  await LocalStorage.setItem(AUTH_KEY, JSON.stringify({ token: t, at: Date.now() }));
  await LocalStorage.setItem(
    TOOLS_KEY,
    JSON.stringify(tools.map((x) => ({ name: x.name, description: x.description, inputSchema: x.inputSchema }))),
  );
  const names = new Set(tools.map((x) => x.name));
  const missing = ["create_task", "update_task", "complete_task"].filter((n) => !names.has(n));
  return { missing, tools: tools.length };
}

// ── 组装参数（按滴答 MCP 的 schema：create_task / update_task 的任务字段放在 `task` 对象里）──

const pad = (n: number) => n.toString().padStart(2, "0");

export function offsetString(): string {
  const off = -new Date().getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  return `${sign}${pad(Math.floor(Math.abs(off) / 60))}${pad(Math.abs(off) % 60)}`;
}

export function timezoneName(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "Asia/Shanghai";
  } catch {
    return "Asia/Shanghai";
  }
}

interface TaskFields {
  content: string;
  date: string;
  time: string | null;
}

/** 任务对象：日期时间用 yyyy-MM-dd'T'HH:mm:ss.000+0800 */
function taskObject(t: TaskFields): Record<string, unknown> {
  const due = `${t.date}T${t.time ?? "00:00"}:00.000${offsetString()}`;
  return {
    title: t.content,
    content: "来自闪念贝壳",
    startDate: due,
    dueDate: due,
    isAllDay: !t.time,
    timeZone: timezoneName(),
    // 有具体时间：准点提醒；只有日期：当天 9:00 提醒
    reminders: [t.time ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"],
  };
}

export function parseJson(text: string): Record<string, unknown> | null {
  const i = text.search(/[{[]/);
  if (i < 0) return null;
  try {
    const v = JSON.parse(text.slice(i));
    return Array.isArray(v) ? ((v[0] as Record<string, unknown>) ?? null) : (v as Record<string, unknown>);
  } catch {
    return null;
  }
}

function pickString(obj: Record<string, unknown> | null, ...keys: string[]): string | undefined {
  if (!obj) return undefined;
  for (const k of keys) {
    const v = obj[k];
    if (typeof v === "string" && v) return v;
  }
  const inner = (obj.task ?? obj.data) as Record<string, unknown> | undefined;
  return inner && typeof inner === "object" ? pickString(inner, ...keys) : undefined;
}

export function extractTaskRef(text: string): { taskId?: string; projectId?: string } {
  const obj = parseJson(text);
  let taskId = pickString(obj, "id", "taskId", "task_id");
  let projectId = pickString(obj, "projectId", "project_id");
  taskId ??= text.match(/(?:task[_ ]?id|\bid)["']?\s*[:：=]\s*["']?([0-9a-zA-Z]{12,})/i)?.[1];
  projectId ??= text.match(/project[_ ]?id["']?\s*[:：=]\s*["']?([0-9a-zA-Z]{6,})/i)?.[1];
  return { taskId, projectId };
}

function isCompletedText(text: string): boolean {
  const obj = parseJson(text);
  const inner = ((obj?.task as Record<string, unknown>) ?? obj) as Record<string, unknown> | null;
  if (inner) {
    if (inner.status === 2 || inner.status === "completed" || inner.status === "Completed") return true;
    if (inner.completedTime || inner.completed_time || inner.isCompleted === true) return true;
    return false;
  }
  return /"status"\s*:\s*2\b/.test(text);
}

const sigOf = (t: { content: string; date: string | null; time: string | null }) =>
  `${t.content}|${t.date ?? ""}|${t.time ?? ""}`;

// ── 映射（闪念贝壳待办 id ↔ 滴答任务 id），可丢弃重建 ──

export async function loadMap(): Promise<Record<string, Mapping>> {
  try {
    const raw = await LocalStorage.getItem<string>(MAP_KEY);
    return raw ? (JSON.parse(raw) as Record<string, Mapping>) : {};
  } catch {
    return {};
  }
}

export async function saveMap(map: Record<string, Mapping>): Promise<void> {
  await LocalStorage.setItem(MAP_KEY, JSON.stringify(map));
}

export async function loadSyncedIds(): Promise<Set<string>> {
  return new Set(Object.keys(await loadMap()));
}

// ── 同步 ──

export interface SyncResult {
  created: number;
  updated: number;
  completedToDida: number;
  completedFromDida: number;
  failed: number;
  /** 第一条失败原因，便于排查 */
  firstError?: string;
  authError?: string;
}

const MAX_REQUESTS = 40;

async function createInDida(t: TaskFields & { id: string }): Promise<Mapping | null> {
  const text = await callDida("create_task", { task: taskObject(t), client_timezone: timezoneName() });
  const ref = extractTaskRef(text);
  if (!ref.taskId) throw new Error(`create_task 的返回里没找到任务 id：${text.slice(0, 120)}`);
  return { taskId: ref.taskId, projectId: ref.projectId, sig: sigOf(t) };
}

/** complete_task / update_task 需要清单 id 而映射里没有时，用 get_task_by_id 补上 */
async function ensureProjectId(m: Mapping): Promise<string> {
  if (!m.projectId) {
    const text = await callDida("get_task_by_id", { task_id: m.taskId });
    m.projectId = extractTaskRef(text).projectId;
  }
  if (!m.projectId) throw new Error("没有取到任务所在的清单 id");
  return m.projectId;
}

/**
 * 同步一轮。open / done 为闪念贝壳当前的未完成 / 最近已完成待办。
 * 只同步带日期的待办（没日期的待办没有提醒意义）。
 */
export async function syncDida(open: TodoItem[], done: TodoItem[]): Promise<SyncResult> {
  const result: SyncResult = { created: 0, updated: 0, completedToDida: 0, completedFromDida: 0, failed: 0 };
  if (!(await isDidaConnected())) return result;

  const map = await loadMap();
  let requests = 0;
  const budget = () => requests < MAX_REQUESTS;
  const fail = (e: unknown) => {
    if (e instanceof DidaAuthError) throw e;
    result.failed++;
    result.firstError ??= e instanceof Error ? e.message : String(e);
  };

  try {
    // 1. 新建 / 更新
    for (const t of open) {
      if (!t.date || !budget()) continue;
      const m = map[t.id];
      const fields = { content: t.content, date: t.date, time: t.time };
      try {
        if (!m) {
          requests++;
          const created = await createInDida({ ...fields, id: t.id });
          if (created) {
            map[t.id] = created;
            result.created++;
          }
        } else if (m.sig !== sigOf(t) && !m.done) {
          requests++;
          const projectId = await ensureProjectId(m);
          await callDida("update_task", {
            task_id: m.taskId,
            task: { id: m.taskId, projectId, ...taskObject(fields) },
            client_timezone: timezoneName(),
          });
          m.sig = sigOf(t);
          result.updated++;
        }
      } catch (e) {
        fail(e);
      }
    }

    // 2. 这边已完成 → 滴答里也完成
    for (const t of done) {
      const m = map[t.id];
      if (!m || m.done || !budget()) continue;
      try {
        requests++;
        await callDida("complete_task", { project_id: await ensureProjectId(m), task_id: m.taskId });
        m.done = true;
        result.completedToDida++;
      } catch (e) {
        fail(e);
      }
    }

    // 3. 滴答里已完成 → 这边也完成（只查有映射、未完成的；没有 get_task_by_id 就跳过）
    const finished: string[] = [];
    for (const t of open.filter((x) => map[x.id] && !map[x.id].done)) {
      if (!budget()) break;
      const m = map[t.id];
      try {
        requests++;
        const text = await callDida("get_task_by_id", { task_id: m.taskId });
        if (!m.projectId) m.projectId = extractTaskRef(text).projectId;
        if (isCompletedText(text)) finished.push(t.id);
      } catch (e) {
        fail(e);
      }
    }
    if (finished.length > 0) {
      await updateTodos(finished.map((id) => ({ todo_id: id, is_completed: true })));
      finished.forEach((id) => (map[id].done = true));
      result.completedFromDida = finished.length;
    }
  } catch (e) {
    if (e instanceof DidaAuthError) result.authError = e.message;
    else throw e;
  } finally {
    await saveMap(map);
    await LocalStorage.setItem(LAST_SYNC_KEY, String(Date.now()));
    await LocalStorage.setItem(LAST_ERROR_KEY, result.authError ?? result.firstError ?? "");
  }
  return result;
}

/** 在本扩展里完成待办后，立刻把完成状态推给滴答（失败不影响主流程） */
export async function pushCompleteToDida(todoId: string): Promise<void> {
  try {
    if (!(await isDidaConnected())) return;
    const map = await loadMap();
    const m = map[todoId];
    if (!m || m.done) return;
    await callDida("complete_task", { project_id: await ensureProjectId(m), task_id: m.taskId });
    m.done = true;
    await saveMap(map);
  } catch {
    // 下次同步时会补上
  }
}

/** 取全量（未完成 + 最近完成）后同步，用于「立即同步」 */
export async function syncAll(): Promise<SyncResult> {
  const [open, done] = await Promise.all([
    listTodos({ isCompleted: false, limit: 200 }),
    listTodos({ isCompleted: true, limit: 20 }),
  ]);
  return syncDida(open, done);
}

export function describeSync(r: SyncResult): string {
  if (r.authError) return r.authError;
  const parts = [
    r.created && `新建 ${r.created}`,
    r.updated && `更新 ${r.updated}`,
    r.completedToDida && `滴答已完成 ${r.completedToDida}`,
    r.completedFromDida && `从滴答带回完成 ${r.completedFromDida}`,
    r.failed && `失败 ${r.failed}${r.firstError ? `（${r.firstError.slice(0, 80)}）` : ""}`,
  ].filter(Boolean);
  return parts.length ? parts.join("，") : "已是最新";
}
