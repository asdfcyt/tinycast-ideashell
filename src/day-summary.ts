import { prependBlockToToday } from "./daily";
import { callDida, isDidaConnected, timezoneName } from "./dida";
import { fetchFocusSummary, formatMinutes } from "./dida-focus";
import { DidaTask, extractTasks, isoLocal, startOfDay } from "./dida-tasks";
import { formatDate } from "./utils";

/**
 * 今日小结：把今天完成的任务、专注时长（按任务拆分）以引用格式插到今天 Daily Note 的最前面。
 * 全部是滴答里的精确数据，不推测、不需要打字。重复生成会替换开头那一块，不会堆叠。
 */

const MAX_TASKS = 20;
const MAX_FOCUS_TASKS = 10;
/** 开头引用块的标记：重复生成时靠它识别并替换 */
const MARKER = "今日小结";

export interface DaySummary {
  tasks: string[];
  focusMin: number;
  focusPomos: number;
  focusByTask: { title: string; min: number }[];
}

const hasContent = (s: DaySummary) => s.tasks.length > 0 || s.focusMin > 0;

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

export async function collectDaySummary(now = new Date()): Promise<DaySummary> {
  if (!(await isDidaConnected()))
    throw new Error("还没有连接滴答清单，无法汇总今天完成的任务和专注");
  const [done, focus] = await Promise.all([
    fetchDoneToday(now),
    fetchFocusSummary(now).catch(() => undefined),
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
  };
}

/** 引用格式：整块每行以 `> ` 开头，细项缩进成子列表，不带时间戳 */
export function formatDaySummary(s: DaySummary): string {
  const lines = [`**${MARKER}**`];
  if (s.tasks.length > 0) {
    lines.push(`- 完成 ${s.tasks.length} 项任务`);
    for (const t of s.tasks.slice(0, MAX_TASKS)) lines.push(`  - ${t}`);
    if (s.tasks.length > MAX_TASKS)
      lines.push(`  - ……还有 ${s.tasks.length - MAX_TASKS} 项`);
  }
  if (s.focusMin > 0) {
    const pomo = s.focusPomos > 0 ? `（${s.focusPomos} 个番茄）` : "";
    lines.push(`- 专注 ${formatMinutes(s.focusMin)}${pomo}`);
    for (const f of s.focusByTask.slice(0, MAX_FOCUS_TASKS))
      lines.push(`  - ${f.title}：${formatMinutes(f.min)}`);
  }
  return lines.map((l) => `> ${l}`).join("\n");
}

/** 汇总并插到今天 Daily Note 的最前面；今天什么都没有时返回 null，不写入 */
export async function writeDaySummary(): Promise<DaySummary | null> {
  const s = await collectDaySummary();
  if (!hasContent(s)) return null;
  await prependBlockToToday(formatDaySummary(s), MARKER);
  return s;
}

export function summaryHud(s: DaySummary | null): string {
  return s
    ? `今日小结已插到 Daily Note 最前面：完成 ${s.tasks.length} 项 · 专注 ${formatMinutes(s.focusMin)}`
    : "今天还没有完成的任务或专注记录";
}
