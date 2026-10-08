import { getNotesInRange, listTodos, NoteInfo, TodoItem } from "./api";
import { lastDayOf, TimeRange, weekdayName } from "./time-range";
import { formatDate, truncate } from "./utils";

export interface DayBucket {
  date: string; // YYYY-MM-DD
  title: string; // 2026-10-08 周四
  notes: NoteInfo[];
  todos: TodoItem[];
}

export interface TimelineData {
  range: TimeRange;
  days: DayBucket[];
  noteCount: number;
  todoDone: number;
  todoTotal: number;
  truncated: boolean;
}

export function localDay(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : formatDate(d);
}

export function localHHmm(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
}

/** 拉取时间范围内的笔记 + 待办，并按天分组（新的在前） */
export async function loadTimeline(range: TimeRange): Promise<TimelineData> {
  const from = formatDate(range.start);
  const to = formatDate(lastDayOf(range));

  const [{ notes, truncated }, open, done] = await Promise.all([
    getNotesInRange(range.start, range.end),
    listTodos({ isCompleted: false, dateFrom: from, dateTo: to, limit: 200 }),
    listTodos({ isCompleted: true, dateFrom: from, dateTo: to, limit: 200 }),
  ]);

  // 无日期待办不属于任何一天；区间外的也丢弃（接口对日期过滤的边界行为未明确，这里再兜底过滤一次）
  const todos = [...open, ...done].filter((t) => t.date && t.date >= from && t.date <= to);

  const map = new Map<string, DayBucket>();
  const bucket = (date: string): DayBucket => {
    let b = map.get(date);
    if (!b) {
      b = { date, title: `${date} ${weekdayName(new Date(`${date}T00:00:00`))}`, notes: [], todos: [] };
      map.set(date, b);
    }
    return b;
  };

  for (const n of notes) {
    const date = localDay(n.created_at);
    if (date) bucket(date).notes.push(n);
  }
  for (const t of todos) bucket(t.date as string).todos.push(t);

  const days = [...map.values()].sort((a, b) => b.date.localeCompare(a.date));
  days.forEach((d) => d.todos.sort((a, b) => (a.time ?? "99:99").localeCompare(b.time ?? "99:99")));

  return {
    range,
    days,
    noteCount: notes.length,
    todoDone: todos.filter((t) => t.is_completed).length,
    todoTotal: todos.length,
    truncated,
  };
}

/** 生成可直接贴进日报/周报的 Markdown */
export function buildReport(data: TimelineData): string {
  const lines = [
    `# ${data.range.label} 回顾`,
    "",
    `> ${data.noteCount} 条笔记 · 待办完成 ${data.todoDone}/${data.todoTotal}`,
  ];

  for (const day of data.days) {
    lines.push("", `## ${day.title}`);
    if (day.notes.length > 0) {
      lines.push("", "**笔记**", "");
      // 同一天内按时间正序更符合阅读习惯
      [...day.notes].reverse().forEach((n) => {
        const time = localHHmm(n.created_at);
        const summary = n.summary ? ` — ${truncate(n.summary.replace(/\s+/g, " "), 80)}` : "";
        lines.push(`- ${time ? `${time} ` : ""}**${n.title}**${summary}`);
      });
    }
    if (day.todos.length > 0) {
      lines.push("", "**待办**", "");
      day.todos.forEach((t) => {
        lines.push(`- [${t.is_completed ? "x" : " "}] ${t.content}${t.time ? `（${t.time}）` : ""}`);
      });
    }
  }
  return lines.join("\n");
}
