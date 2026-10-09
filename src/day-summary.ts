import { getNotesInRange } from "./api";
import { appendToToday, extractDate } from "./daily";
import { callDida, isDidaConnected, timezoneName } from "./dida";
import { fetchFocusSummary, formatMinutes } from "./dida-focus";
import { DidaTask, extractTasks, isoLocal, startOfDay } from "./dida-tasks";
import { formatDate } from "./utils";

/**
 * 今日小结：把今天完成的任务、专注时长、新记的笔记标题汇总追加到今天的 Daily Note。
 * 全部是接口里的精确数据，不推测、不需要打字。
 */

const MAX_TASKS = 12;
const MAX_NOTES = 10;
const MAX_FOCUS_TASKS = 6;

export interface DaySummary {
  tasks: string[];
  focusMin: number;
  focusPomos: number;
  focusByTask: { title: string; min: number }[];
  notes: string[];
}

const hasContent = (s: DaySummary) =>
  s.tasks.length > 0 || s.focusMin > 0 || s.notes.length > 0;

async function fetchDoneToday(now: Date): Promise<DidaTask[]> {
  const text = await callDida("list_completed_tasks_by_date", {
    search: {
      startDate: isoLocal(startOfDay(now)),
      endDate: isoLocal(startOfDay(now, 1)),
    },
    client_timezone: timezoneName(),
  });
  const today = formatDate(now);
  return extractTasks(text)
    .filter((t) => t.done)
    .filter(
      (t) => !t.completedAt || formatDate(new Date(t.completedAt)) === today,
    )
    .sort((a, b) => (a.completedAt ?? 0) - (b.completedAt ?? 0));
}

/** 今天新建的笔记标题（排除 Daily Note 本身） */
async function fetchNotesToday(now: Date): Promise<string[]> {
  const { notes } = await getNotesInRange(startOfDay(now), now);
  return notes
    .filter((n) => !(n.tags ?? []).some((t) => /^#?daily-?note$/i.test(t)))
    .map((n) => (n.title || n.summary || "").trim())
    .filter((t) => t && extractDate(t) !== t)
    .filter((t, i, arr) => arr.indexOf(t) === i);
}

export async function collectDaySummary(now = new Date()): Promise<DaySummary> {
  const connected = await isDidaConnected();
  const [done, focus, notes] = await Promise.all([
    connected ? fetchDoneToday(now).catch(() => [] as DidaTask[]) : [],
    connected ? fetchFocusSummary(now).catch(() => undefined) : undefined,
    fetchNotesToday(now).catch(() => [] as string[]),
  ]);

  const titles: Record<string, string> = { ...(focus?.titles ?? {}) };
  for (const t of done) titles[t.id] ??= t.title;

  const focusByTask = Object.entries(focus?.byTask ?? {})
    .filter(([, f]) => f.todayMin > 0)
    .map(([id, f]) => ({
      title: titles[id] ?? "（未关联任务）",
      min: f.todayMin,
    }))
    .sort((a, b) => b.min - a.min);

  return {
    tasks: done.map((t) => t.title),
    focusMin: focus?.todayMin ?? 0,
    focusPomos: focus?.todayPomos ?? 0,
    focusByTask,
    notes,
  };
}

function more(total: number, shown: number): string {
  return total > shown ? `、……共 ${total} 项` : "";
}

/** 排成追加到 Daily Note 的文字（第一行是标题，后面是子列表） */
export function formatDaySummary(s: DaySummary): string {
  const lines = ["今日小结"];
  if (s.tasks.length > 0)
    lines.push(
      `- 完成 ${s.tasks.length} 项任务：${s.tasks.slice(0, MAX_TASKS).join("、")}${more(s.tasks.length, MAX_TASKS)}`,
    );
  if (s.focusMin > 0) {
    const pomo = s.focusPomos > 0 ? `（${s.focusPomos} 个番茄）` : "";
    const per = s.focusByTask
      .slice(0, MAX_FOCUS_TASKS)
      .map((f) => `${f.title} ${formatMinutes(f.min)}`)
      .join("；");
    lines.push(
      `- 专注 ${formatMinutes(s.focusMin)}${pomo}${per ? `：${per}` : ""}`,
    );
  }
  if (s.notes.length > 0)
    lines.push(
      `- 记了 ${s.notes.length} 条笔记：${s.notes.slice(0, MAX_NOTES).join("、")}${more(s.notes.length, MAX_NOTES)}`,
    );
  return lines.join("\n");
}

/** 汇总并追加到今天的 Daily Note；今天什么都没有时返回 null，不写入 */
export async function writeDaySummary(): Promise<DaySummary | null> {
  const s = await collectDaySummary();
  if (!hasContent(s)) return null;
  await appendToToday(formatDaySummary(s));
  return s;
}
