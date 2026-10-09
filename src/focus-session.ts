import { LocalStorage, showHUD } from "@raycast/api";
import { execFile } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { callDida, loadDidaToken, timezoneName } from "./dida";
import { formatMinutes } from "./dida-focus";
import {
  collectObjects,
  commentOnTask,
  isoLocal,
  parseAny,
} from "./dida-tasks";
import { appendProgress, loadTaskNotes } from "./task-notes";

/**
 * 专注计时器（自己计时，不依赖滴答的番茄钟）：
 * - 开始：记下任务和起止时间，起一个后台小脚本负责到点提醒（通知 + 提示音）并把专注记录写进滴答；
 * - 菜单栏显示剩余分钟，随菜单栏后台刷新更新；
 * - 结束（或提前结束）后：滴答里出现一条绑定了任务的专注记录（`create_focus`），
 *   再把时长写入任务笔记「进展记录」和滴答评论。
 * 脚本没能运行（比如被系统清理）时，下次刷新由这里补写记录，保证不丢。
 */

const SESSION_KEY = "focus-session-v1";
const LAST_MIN_KEY = "focus-last-minutes-v1";
export const FOCUS_CHOICES = [15, 25, 45, 60, 90];
const DEFAULT_MINUTES = 25;
/** 脚本记录起点与计划起点的容许误差 */
const MATCH_WINDOW_MS = 3 * 60000;
/** 计划结束后等脚本这么久还没有记录，就由扩展自己补写 */
const FALLBACK_AFTER_MS = 3 * 60000;
const MCP_URL = "https://mcp.dida365.com";

export interface FocusSession {
  taskKey: string;
  taskId: string;
  projectId: string;
  title: string;
  start: number;
  minutes: number;
  /** 后台脚本是否已成功启动 */
  scripted?: boolean;
  /** 正在对账的时间戳，防止菜单栏和后台同时处理 */
  settling?: number;
}

export async function readSession(): Promise<FocusSession | undefined> {
  try {
    const raw = await LocalStorage.getItem<string>(SESSION_KEY);
    return raw ? (JSON.parse(raw) as FocusSession) : undefined;
  } catch {
    return undefined;
  }
}

async function saveSession(s: FocusSession): Promise<void> {
  await LocalStorage.setItem(SESSION_KEY, JSON.stringify(s));
}

export async function lastMinutes(): Promise<number> {
  const raw = await LocalStorage.getItem<string | number>(LAST_MIN_KEY);
  const n = Number(raw);
  return FOCUS_CHOICES.includes(n) ? n : DEFAULT_MINUTES;
}

export async function setLastMinutes(n: number): Promise<void> {
  await LocalStorage.setItem(LAST_MIN_KEY, String(n));
}

export const sessionEnd = (s: FocusSession) => s.start + s.minutes * 60000;

export function hhmm(ms: number): string {
  const d = new Date(ms);
  return `${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
}

/** 距结束还剩几分钟（向上取整，最少 1）；已到点返回 0 */
export function remainingMinutes(s: FocusSession, now = Date.now()): number {
  const left = sessionEnd(s) - now;
  return left <= 0 ? 0 : Math.max(1, Math.ceil(left / 60000));
}

// ── 后台脚本 ──

const markerPath = (s: FocusSession) =>
  path.join(os.tmpdir(), `ideashell-focus-${s.start}.on`);
const scriptPath = (s: FocusSession) =>
  path.join(os.tmpdir(), `ideashell-focus-${s.start}.sh`);

/** 单引号包起来，安全地放进 shell 脚本 */
const q = (v: string) => `'${v.replace(/'/g, `'\\''`)}'`;

function rpcBody(
  method: string,
  params?: Record<string, unknown>,
  id?: number,
) {
  return JSON.stringify({
    jsonrpc: "2.0",
    ...(id !== undefined ? { id } : {}),
    method,
    ...(params ? { params } : {}),
  });
}

function buildScript(s: FocusSession, token: string): string {
  const args = {
    start_time: new Date(s.start).toISOString(),
    end_time: new Date(sessionEnd(s)).toISOString(),
    type: 0,
    task_id: s.taskId,
    client_timezone: timezoneName(),
  };
  const init = rpcBody(
    "initialize",
    {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "tinycast-ideashell-focus", version: "1.0.0" },
    },
    1,
  );
  const inited = rpcBody("notifications/initialized");
  const call = rpcBody(
    "tools/call",
    { name: "create_focus", arguments: args },
    2,
  );
  return `#!/bin/sh
# 专注计时脚本：到点提醒，并把专注记录写进滴答（由 Tinycast 的「闪念贝壳」扩展生成）
M=${q(markerPath(s))}
SELF=${q(scriptPath(s))}
END=${Math.floor(sessionEnd(s) / 1000)}
trap 'rm -f "$SELF"' EXIT
# 每 5 秒看一眼时钟，睡眠唤醒后也能很快反应过来
while [ "$(date +%s)" -lt "$END" ]; do
  [ -f "$M" ] || exit 0
  sleep 5
done
[ -f "$M" ] || exit 0
rm -f "$M"
/usr/bin/osascript -e 'on run argv' -e 'display notification ("专注 ${s.minutes} 分钟已完成：" & item 1 of argv) with title "专注结束" sound name "Glass"' -e 'end run' -- ${q(s.title)} >/dev/null 2>&1
/usr/bin/afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
URL=${q(MCP_URL)}
AUTH=${q(`Authorization: Bearer ${token}`)}
HDRS=$(/usr/bin/curl -s -m 20 -D - -o /dev/null -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "$AUTH" -d ${q(init)})
SID=$(printf '%s' "$HDRS" | /usr/bin/awk 'tolower($1)=="mcp-session-id:"{print $2}' | /usr/bin/tr -d '\\r')
/usr/bin/curl -s -m 20 -o /dev/null -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "$AUTH" -H "Mcp-Session-Id: $SID" -d ${q(inited)}
/usr/bin/curl -s -m 30 -o /dev/null -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "$AUTH" -H "Mcp-Session-Id: $SID" -d ${q(call)}
`;
}

function launchScript(s: FocusSession, token: string): Promise<void> {
  fs.writeFileSync(markerPath(s), String(Date.now()));
  fs.writeFileSync(scriptPath(s), buildScript(s, token), { mode: 0o700 });
  return new Promise((resolve, reject) => {
    execFile(
      "/bin/sh",
      ["-c", `/usr/bin/nohup /bin/sh ${q(scriptPath(s))} >/dev/null 2>&1 &`],
      { timeout: 10000 },
      (err) => (err ? reject(err) : resolve()),
    );
  });
}

function removeMarker(s: FocusSession): boolean {
  try {
    const had = fs.existsSync(markerPath(s));
    fs.rmSync(markerPath(s), { force: true });
    return had;
  } catch {
    return false;
  }
}

function cleanupScript(s: FocusSession): void {
  try {
    fs.rmSync(scriptPath(s), { force: true });
  } catch {
    // 忽略
  }
}

// ── 开始 / 取消 / 提前结束 ──

export async function startFocus(
  row: {
    key: string;
    id: string;
    projectId: string;
    title: string;
    source: "dida" | "idea";
  },
  minutes: number,
): Promise<FocusSession> {
  if (row.source !== "dida")
    throw new Error("只有滴答里的任务可以开始专注（专注记录要绑定到滴答任务）");
  const existing = await readSession();
  if (existing)
    throw new Error(
      `已经有一个专注：${existing.title}（${hhmm(sessionEnd(existing))} 结束）。可先在菜单栏结束或放弃`,
    );
  const token = await loadDidaToken();
  if (!token) throw new Error("还没有连接滴答清单");
  const m = Math.min(180, Math.max(5, Math.round(minutes)));
  const s: FocusSession = {
    taskKey: row.key,
    taskId: row.id,
    projectId: row.projectId,
    title: row.title,
    start: Date.now(),
    minutes: m,
  };
  try {
    await launchScript(s, token);
    s.scripted = true;
  } catch {
    // 后台脚本起不来也能计时：到点后下次刷新时由扩展补写记录，只是不会准点提醒
    s.scripted = false;
  }
  await saveSession(s);
  await setLastMinutes(m).catch(() => undefined);
  return s;
}

/** 放弃：不记录 */
export async function dropFocus(): Promise<void> {
  const s = await readSession();
  if (s) {
    removeMarker(s);
    cleanupScript(s);
  }
  await LocalStorage.removeItem(SESSION_KEY);
}

/** 提前结束：按已专注的时间记录（不足 1 分钟则不记录） */
export async function finishFocusEarly(): Promise<
  { minutes: number } | undefined
> {
  const s = await readSession();
  if (!s) return undefined;
  removeMarker(s);
  cleanupScript(s);
  const end = Math.min(Date.now(), sessionEnd(s));
  if (end - s.start < 60000) {
    await LocalStorage.removeItem(SESSION_KEY);
    return undefined;
  }
  const minutes = Math.round((end - s.start) / 60000);
  await createRecord(s, s.start, end);
  await writeProgress(s, minutes);
  await LocalStorage.removeItem(SESSION_KEY);
  return { minutes };
}

// ── 写入滴答 / 任务笔记 ──

async function createRecord(
  s: FocusSession,
  start: number,
  end: number,
): Promise<void> {
  await callDida("create_focus", {
    start_time: new Date(start).toISOString(),
    end_time: new Date(end).toISOString(),
    type: 0,
    task_id: s.taskId,
    client_timezone: timezoneName(),
  });
}

async function writeProgress(s: FocusSession, minutes: number): Promise<void> {
  const text = `专注 ${formatMinutes(minutes)}`;
  try {
    const note = (await loadTaskNotes())[s.taskKey];
    if (note) await appendProgress(note.noteId, text);
  } catch {
    // 任务笔记写入失败不影响其余步骤
  }
  await commentOnTask(s.taskKey, `进展：${text}`, s.projectId).catch(
    () => false,
  );
}

const ms = (v: unknown): number | null => {
  if (typeof v !== "string") return null;
  const t = Date.parse(v.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
  return Number.isNaN(t) ? null : t;
};

/** 滴答里有没有这次专注的记录（脚本写入的，起点和计划起点基本一致） */
async function hasRecord(s: FocusSession): Promise<boolean> {
  const text = await callDida("get_focuses_by_time", {
    from_time: isoLocal(new Date(s.start - 15 * 60000)),
    to_time: isoLocal(new Date(sessionEnd(s) + 15 * 60000)),
    type: 0,
  });
  const found: Record<string, unknown>[] = [];
  collectObjects(
    parseAny(text),
    (o) => typeof o.startTime === "string" && typeof o.endTime === "string",
    found,
  );
  return found.some((o) => {
    const st = ms(o.startTime);
    return st !== null && Math.abs(st - s.start) <= MATCH_WINDOW_MS;
  });
}

export type SettleResult =
  | { status: "none" }
  | { status: "running"; session: FocusSession }
  | { status: "done"; session: FocusSession; minutes: number };

/**
 * 到点后的收尾：确认滴答里已有记录（没有就补写），再写入任务笔记和评论。
 * 随时可以调用（菜单栏、后台刷新、打开待办列表时）；没有进行中的专注时几乎没有开销。
 */
export async function settleFocus(): Promise<SettleResult> {
  const s = await readSession();
  if (!s) return { status: "none" };
  const now = Date.now();
  if (now < sessionEnd(s)) return { status: "running", session: s };
  if (s.settling && now - s.settling < 2 * 60000)
    return { status: "running", session: s };

  // 脚本正常的话，它到点就写了记录；给它几分钟，没有再补
  const exists = await hasRecord(s).catch(() => false);
  if (!exists) {
    if (s.scripted && now < sessionEnd(s) + FALLBACK_AFTER_MS)
      return { status: "running", session: s };
    await saveSession({ ...s, settling: now });
    removeMarker(s); // 让脚本别再重复写
    await createRecord(s, s.start, sessionEnd(s));
  } else {
    await saveSession({ ...s, settling: now });
  }
  cleanupScript(s);
  await writeProgress(s, s.minutes);
  await LocalStorage.removeItem(SESSION_KEY);
  return { status: "done", session: s, minutes: s.minutes };
}

/** 收尾并弹出结果提示（出错静默，下次再试） */
export async function settleAndNotify(): Promise<SettleResult> {
  try {
    const r = await settleFocus();
    if (r.status === "done")
      await showHUD(
        `专注结束：${r.session.title} · ${formatMinutes(r.minutes)}已记入滴答和任务`,
      ).catch(() => undefined);
    return r;
  } catch {
    return { status: "none" };
  }
}
