import { LocalStorage } from "@raycast/api";
import { callDida, extractTaskRef, offsetString, timezoneName } from "./dida";
import { formatDate } from "./utils";

/**
 * 滴答清单任务的读取 / 修改（通过官方 MCP）。Todos 以滴答为主：
 * 逾期 / 今天 / 近 7 天 / 最近完成的任务都从这里拉取。
 */

export interface DidaTask {
  id: string;
  projectId: string;
  title: string;
  content: string;
  /** 本地日期 YYYY-MM-DD；无截止日期为 null */
  date: string | null;
  /** 本地时间 HH:MM；全天任务为 null */
  time: string | null;
  priority: number;
  tags: string[];
  done: boolean;
}

export interface DidaOverview {
  overdue: DidaTask[];
  upcoming: DidaTask[];
  done: DidaTask[];
  projects: Record<string, string>;
  /** 部分请求失败时的说明 */
  warning?: string;
}

const pad = (n: number) => n.toString().padStart(2, "0");
const PROJECTS_KEY = "dida-projects-v1";
const PROJECTS_TTL = 6 * 3600 * 1000;

/** 本地时间 → `2026-10-09T15:00:00.000+0800` */
function isoLocal(d: Date): string {
  return `${formatDate(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.000${offsetString()}`;
}

function startOfDay(d: Date, plusDays = 0): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + plusDays, 0, 0, 0);
}

/** 解析滴答返回的日期（可能是 UTC，也可能带 +0800 / +08:00），换算成本地日期 / 时间 */
export function parseDidaDate(value: unknown, isAllDay: boolean): { date: string | null; time: string | null } {
  if (typeof value !== "string") return { date: null, time: null };
  const m = value.match(
    /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$/,
  );
  if (!m) return { date: null, time: null };
  if (!m[4]) return { date: `${m[1]}-${m[2]}-${m[3]}`, time: null };
  let offsetMin = 0;
  if (m[7] && m[7] !== "Z") {
    const sign = m[7][0] === "-" ? -1 : 1;
    const digits = m[7].slice(1).replace(":", "");
    offsetMin = sign * (+digits.slice(0, 2) * 60 + +digits.slice(2, 4));
  }
  const utc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)) - offsetMin * 60000;
  const local = new Date(utc);
  return { date: formatDate(local), time: isAllDay ? null : `${pad(local.getHours())}:${pad(local.getMinutes())}` };
}

function collectObjects(value: unknown, pred: (o: Record<string, unknown>) => boolean, out: Record<string, unknown>[]) {
  if (Array.isArray(value)) {
    for (const v of value) collectObjects(v, pred, out);
  } else if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    if (pred(o)) out.push(o);
    else for (const v of Object.values(o)) collectObjects(v, pred, out);
  }
}

/** 滴答返回的可能是单个 JSON、数组，或多个 JSON 对象首尾相接（每个任务一个对象）→ 全部解析出来 */
function parseAny(text: string): unknown {
  const values: unknown[] = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c !== "{" && c !== "[") {
      i++;
      continue;
    }
    let depth = 0;
    let inStr = false;
    let esc = false;
    let end = -1;
    for (let j = i; j < text.length; j++) {
      const ch = text[j];
      if (inStr) {
        if (esc) esc = false;
        else if (ch === "\\") esc = true;
        else if (ch === '"') inStr = false;
      } else if (ch === '"') inStr = true;
      else if (ch === "{" || ch === "[") depth++;
      else if (ch === "}" || ch === "]") {
        depth--;
        if (depth === 0) {
          end = j;
          break;
        }
      }
    }
    if (end < 0) break;
    try {
      values.push(JSON.parse(text.slice(i, end + 1)));
    } catch {
      // 跳过无法解析的片段
    }
    i = end + 1;
  }
  return values;
}

export function extractTasks(text: string): DidaTask[] {
  const found: Record<string, unknown>[] = [];
  collectObjects(parseAny(text), (o) => typeof o.id === "string" && typeof o.title === "string", found);
  const seen = new Set<string>();
  const tasks: DidaTask[] = [];
  for (const o of found) {
    const id = o.id as string;
    if (seen.has(id)) continue;
    seen.add(id);
    const allDay = o.isAllDay === true;
    const due = parseDidaDate(o.dueDate ?? o.startDate, allDay);
    tasks.push({
      id,
      projectId: typeof o.projectId === "string" ? o.projectId : "",
      title: o.title as string,
      content: typeof o.content === "string" ? o.content : typeof o.desc === "string" ? o.desc : "",
      date: due.date,
      time: due.time,
      priority: typeof o.priority === "number" ? o.priority : 0,
      tags: Array.isArray(o.tags) ? o.tags.filter((t): t is string => typeof t === "string") : [],
      done: o.status === 2 || !!o.completedTime,
    });
  }
  return tasks;
}

/** 保存一份原始返回的开头，便于排查格式问题 */
async function saveSample(tool: string, text: string) {
  try {
    await LocalStorage.setItem(`dida-sample-${tool}`, text.slice(0, 1500));
  } catch {
    // 忽略
  }
}

export async function loadProjectNames(force = false): Promise<Record<string, string>> {
  try {
    const raw = await LocalStorage.getItem<string>(PROJECTS_KEY);
    const cache = raw ? (JSON.parse(raw) as { at: number; names: Record<string, string> }) : null;
    if (cache && !force && Date.now() - cache.at < PROJECTS_TTL && Object.keys(cache.names).length > 0)
      return cache.names;
  } catch {
    // 重新拉取
  }
  const text = await callDida("list_projects", {});
  await saveSample("list_projects", text);
  const found: Record<string, unknown>[] = [];
  collectObjects(parseAny(text), (o) => typeof o.id === "string" && typeof o.name === "string", found);
  const names: Record<string, string> = {};
  for (const o of found) names[o.id as string] = o.name as string;
  for (const [id, name] of Object.entries(names)) if (/^inbox/i.test(id) && /inbox/i.test(name)) names[id] = "收集箱";
  await LocalStorage.setItem(PROJECTS_KEY, JSON.stringify({ at: Date.now(), names }));
  return names;
}

/** 项目名显示：收集箱 id 形如 inbox1011888736 */
export function projectLabel(names: Record<string, string>, projectId: string): string {
  return names[projectId] ?? (/^inbox/i.test(projectId) ? "收集箱" : "");
}

/** 拉取逾期（近 13 天）/ 今天起 7 天 / 最近完成（近 3 天），接口单次最多 14 天 */
export async function fetchDidaOverview(now = new Date()): Promise<DidaOverview> {
  const tz = timezoneName();
  const range = (from: number, to: number) => ({
    search: { startDate: isoLocal(startOfDay(now, from)), endDate: isoLocal(startOfDay(now, to + 1)) },
    client_timezone: tz,
  });
  const query = (q: string) => ({ query_command: q, client_timezone: tz });
  // 按日期区间 + 按「今天 / 未来 7 天」两种方式各拉一遍再合并：区间查询对全天任务的边界处理不一，互相补漏
  const calls: [string, string, Record<string, unknown>][] = [
    ["undone_overdue", "list_undone_tasks_by_date", range(-13, 0)],
    ["undone_upcoming", "list_undone_tasks_by_date", range(-1, 7)],
    ["undone_today", "list_undone_tasks_by_time_query", query("today")],
    ["undone_next7", "list_undone_tasks_by_time_query", query("next7day")],
    ["completed", "list_completed_tasks_by_date", range(-3, 0)],
  ];
  const [results, names] = await Promise.all([
    Promise.allSettled(calls.map(([, tool, args]) => callDida(tool, args))),
    loadProjectNames().catch(() => ({}) as Record<string, string>),
  ]);

  const failures: string[] = [];
  const texts = new Map<string, string>();
  for (let i = 0; i < calls.length; i++) {
    const r = results[i];
    const key = calls[i][0];
    if (r.status === "fulfilled") {
      texts.set(key, r.value);
      await saveSample(key, r.value);
    } else {
      const msg = r.reason instanceof Error ? r.reason.message : String(r.reason);
      texts.set(key, "");
      failures.push(`${key}：${msg}`);
      await saveSample(key, `ERROR: ${msg}`);
    }
  }
  if (failures.length === calls.length) throw new Error(failures[0]);

  const today = formatDate(now);
  const limit = addDaysString(now, 7);
  // 未完成任务：合并去重；只保留逾期（近 13 天）到未来 7 天内、有日期的
  const open = new Map<string, DidaTask>();
  for (const key of ["undone_overdue", "undone_upcoming", "undone_today", "undone_next7"]) {
    for (const t of extractTasks(texts.get(key) ?? "")) {
      if (t.done || !t.date || t.date > limit || open.has(t.id)) continue;
      open.set(t.id, t);
    }
  }
  const all = [...open.values()];
  return {
    overdue: all.filter((t) => (t.date as string) < today),
    upcoming: all.filter((t) => (t.date as string) >= today),
    done: extractTasks(texts.get("completed") ?? "").map((t) => ({ ...t, done: true })),
    projects: names,
    warning: failures.length ? `部分滴答请求失败：${failures.join("；")}` : undefined,
  };
}

function addDaysString(d: Date, days: number): string {
  return formatDate(new Date(d.getFullYear(), d.getMonth(), d.getDate() + days));
}

export interface TaskFieldsInput {
  title?: string;
  content?: string;
  /** null = 不改；传空字符串不支持清除 */
  date?: string | null;
  time?: string | null;
  /** 0 无 / 1 低 / 3 中 / 5 高 */
  priority?: number;
  tags?: string[];
  projectId?: string;
  /** 0 进行中 / 2 已完成（用于恢复） */
  status?: number;
}

/** 组装任务对象；只带传入的字段（更新时只改这些） */
function taskPayload(f: TaskFieldsInput): Record<string, unknown> {
  const t: Record<string, unknown> = {};
  if (f.title !== undefined) t.title = f.title;
  if (f.content !== undefined) t.content = f.content;
  if (f.priority !== undefined) t.priority = f.priority;
  if (f.tags) t.tags = f.tags;
  if (f.projectId) t.projectId = f.projectId;
  if (f.status !== undefined) t.status = f.status;
  if (f.date) {
    const due = `${f.date}T${f.time ?? "00:00"}:00.000${offsetString()}`;
    t.startDate = due;
    t.dueDate = due;
    t.isAllDay = !f.time;
    t.timeZone = timezoneName();
    // 有具体时间：准点提醒；只有日期：当天 9:00 提醒
    t.reminders = [f.time ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"];
  }
  return t;
}

export async function createDidaTask(f: TaskFieldsInput): Promise<{ taskId: string; projectId: string }> {
  const text = await callDida("create_task", { task: taskPayload(f), client_timezone: timezoneName() });
  const ref = extractTaskRef(text);
  if (!ref.taskId) throw new Error(`create_task 的返回里没找到任务 id：${text.slice(0, 120)}`);
  return { taskId: ref.taskId, projectId: ref.projectId ?? "" };
}

export async function patchDidaTask(task: { id: string; projectId: string }, f: TaskFieldsInput): Promise<void> {
  await callDida("update_task", {
    task_id: task.id,
    task: { id: task.id, projectId: task.projectId, ...taskPayload(f) },
    client_timezone: timezoneName(),
  });
}

export async function completeDidaTask(task: { id: string; projectId: string }): Promise<void> {
  await callDida("complete_task", { project_id: task.projectId, task_id: task.id });
}

export const didaTaskUrl = (task: { id: string; projectId: string }) =>
  `https://dida365.com/webapp/#p/${task.projectId}/tasks/${task.id}`;
