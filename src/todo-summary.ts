import { LocalStorage, updateCommandMetadata } from "@raycast/api";
import { checkinHabit, fetchPendingHabits, PendingHabit } from "./dida-habits";
import { clearPostpone } from "./postpone";
import { loadTodoData, TodoRow, todayString } from "./todo-data";
import { projectOf } from "./todo-meta";
import { completeRow } from "./todo-ops";
import { loadTaskNotes, milestoneText, recordMilestone } from "./task-notes";
import { loadWatchlist } from "./watchlist";

/**
 * 今日待办摘要：菜单栏和根搜索副标题共用。
 * 只是 Todos List 数据的一个快照，存在本地缓存里，随时可丢弃重建。
 */
export interface TodoSummary {
  updatedAt: number;
  connected: boolean;
  /** 已逾期（按日期从旧到新） */
  overdue: TodoRow[];
  /** 今天（按时间） */
  today: TodoRow[];
  /** 下一个要做的：今天还没过时间的第一条，没有则今天的第一条 */
  next?: TodoRow;
  /** 今天还没打卡的滴答习惯 */
  habits: PendingHabit[];
}

const KEY = "todo-summary-v1";
/** 这么久之内的缓存直接用，避免每次点开菜单都重新拉一遍滴答 */
const FRESH_MS = 90 * 1000;

const byDateTime = (a: TodoRow, b: TodoRow) =>
  `${a.date ?? ""} ${a.time ?? ""}`.localeCompare(`${b.date ?? ""} ${b.time ?? ""}`);

export async function readSummary(): Promise<TodoSummary | undefined> {
  try {
    const raw = await LocalStorage.getItem<string>(KEY);
    if (!raw) return undefined;
    const s = JSON.parse(raw) as TodoSummary;
    return { ...s, habits: s.habits ?? [] };
  } catch {
    return undefined;
  }
}

async function writeSummary(s: TodoSummary): Promise<void> {
  await LocalStorage.setItem(KEY, JSON.stringify(s));
}

export function buildSummary(
  open: TodoRow[],
  connected: boolean,
  habits: PendingHabit[] = [],
  now = new Date(),
): TodoSummary {
  const today = todayString();
  const pending = open.filter((r) => !r.done && r.date);
  const overdue = pending.filter((r) => (r.date as string) < today).sort(byDateTime);
  const todays = pending.filter((r) => r.date === today).sort(byDateTime);
  const hhmm = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  const next = todays.find((r) => r.time && r.time >= hhmm) ?? todays.find((r) => !r.time) ?? todays[0];
  return { updatedAt: Date.now(), connected, overdue, today: todays, next, habits };
}

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}…` : s);

export const isEmptySummary = (s: TodoSummary) =>
  s.today.length === 0 && s.overdue.length === 0 && s.habits.length === 0;

/** 根搜索里显示在命令名旁边的副标题 */
export function subtitleOf(s: TodoSummary): string {
  if (isEmptySummary(s)) return "今天没有待办 ✓";
  const parts = [`今天 ${s.today.length}`];
  if (s.overdue.length > 0) parts.push(`逾期 ${s.overdue.length}`);
  if (s.habits.length > 0) parts.push(`习惯 ${s.habits.length} 未打卡`);
  if (s.next) parts.push(`下一个 ${[s.next.time, clip(s.next.title, 12)].filter(Boolean).join(" ")}`);
  return parts.join(" · ");
}

/** 菜单栏上的文字 */
export function menuTitleOf(s: TodoSummary): string {
  if (isEmptySummary(s)) return "✓";
  const parts = [String(s.today.length)];
  if (s.overdue.length > 0) parts.push(`逾期${s.overdue.length}`);
  if (s.habits.length > 0) parts.push(`习惯${s.habits.length}`);
  return parts.join(" · ");
}

/**
 * 取摘要：缓存够新就直接用，否则重新拉取并写缓存，同时刷新当前命令在根搜索里的副标题。
 * force = true（后台定时刷新）时总是重新拉取。
 */
export async function refreshSummary(force = false): Promise<TodoSummary> {
  if (!force) {
    const cached = await readSummary();
    if (cached && Date.now() - cached.updatedAt < FRESH_MS) return cached;
  }
  const [data, habits] = await Promise.all([loadTodoData(), fetchPendingHabits().catch(() => [] as PendingHabit[])]);
  const summary = buildSummary(data.open, data.connected, data.connected ? habits : []);
  await writeSummary(summary);
  await updateCommandMetadata({ subtitle: subtitleOf(summary) }).catch(() => undefined);
  return summary;
}

/** 在菜单栏里点掉一条：和 Todos List 里的「标记完成」一样（清推迟计数、记项目里程碑），并立即更新缓存 */
export async function completeFromMenu(row: TodoRow): Promise<TodoSummary | undefined> {
  await completeRow(row);
  await clearPostpone(row.key).catch(() => undefined);
  try {
    const project = projectOf(row.title, await loadWatchlist(), row.tags);
    if (project) {
      const ref = (await loadTaskNotes())[row.key];
      await recordMilestone(project.keyword, milestoneText(row.title, ref));
    }
  } catch {
    // 里程碑失败不影响完成
  }
  const cached = await readSummary();
  if (!cached) return undefined;
  const next = buildSummary(
    [...cached.overdue, ...cached.today].filter((r) => r.key !== row.key),
    cached.connected,
    cached.habits,
  );
  await writeSummary(next);
  await updateCommandMetadata({ subtitle: subtitleOf(next) }).catch(() => undefined);
  return next;
}

/** 在菜单栏里给习惯打卡，并立即更新缓存 */
export async function checkinFromMenu(habit: PendingHabit): Promise<TodoSummary | undefined> {
  await checkinHabit(habit);
  const cached = await readSummary();
  if (!cached) return undefined;
  const next: TodoSummary = { ...cached, habits: cached.habits.filter((h) => h.id !== habit.id) };
  await writeSummary(next);
  await updateCommandMetadata({ subtitle: subtitleOf(next) }).catch(() => undefined);
  return next;
}
