import { getNoteId, NoteDetail, NoteInfo, TodoItem } from "./api";
import { DetailDoc, DocItem, DocRow, makeDoc } from "./detail-doc";
import { extractTags, memoText, wordCount } from "./note-text";
import { lastDayOf, weekdayName } from "./time-range";
import { buildReport, DayBucket, localHHmm, PrevStats, TimelineData } from "./timeline-data";
import { formatDate, truncate } from "./utils";

type Details = Record<string, NoteDetail>;

// ── 小工具 ──

const hourOf = (iso?: string): number | null => {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.getHours();
};

/** 横向柱：与数字配合，放在元信息行右侧 */
const bar = (n: number, max: number, width = 16) =>
  n > 0 && max > 0 ? "█".repeat(Math.max(1, Math.round((n / max) * width))) : "";

const progress = (done: number, total: number, width = 12) => {
  const filled = total > 0 ? Math.round((done / total) * width) : 0;
  return "█".repeat(filled) + "░".repeat(width - filled);
};

const pct = (done: number, total: number) => (total > 0 ? `${Math.round((done / total) * 100)}%` : "-");

/** 与对比期的差值：+3 / -2 / 持平 */
function delta(cur: number, prev: number | undefined, vs: string): string {
  if (prev === undefined) return "";
  const d = cur - prev;
  return d === 0 ? `　与${vs}持平` : `　较${vs} ${d > 0 ? "+" : "-"}${Math.abs(d)}`;
}

const PERIODS: Array<[string, number, number]> = [
  ["凌晨 00-06", 0, 6],
  ["上午 06-12", 6, 12],
  ["下午 12-18", 12, 18],
  ["晚上 18-24", 18, 24],
];

function periodRows(notes: NoteInfo[]): { rows: DocRow[]; peak?: string } {
  const hours = notes.map((n) => hourOf(n.created_at)).filter((h): h is number => h !== null);
  if (hours.length === 0) return { rows: [] };
  const counts = PERIODS.map(([, a, b]) => hours.filter((h) => h >= a && h < b).length);
  const max = Math.max(...counts);
  const rows = PERIODS.map(([title], i) => ({
    title,
    text: counts[i] > 0 ? `${bar(counts[i], max)} ${counts[i]}` : "-",
  }));

  const perHour = new Array<number>(24).fill(0);
  hours.forEach((h) => (perHour[h] += 1));
  const peakHour = perHour.indexOf(Math.max(...perHour));
  const pad = (h: number) => String(h).padStart(2, "0");
  return { rows, peak: `${pad(peakHour)}:00 - ${pad((peakHour + 1) % 24)}:00` };
}

/** 汇总：标签榜、总字数（仅统计已加载正文的笔记） */
function analyzeContent(notes: NoteInfo[], details: Details) {
  const tagCount = new Map<string, number>();
  let words = 0;
  let loaded = 0;
  for (const n of notes) {
    const d = details[getNoteId(n)];
    if (!d) continue;
    loaded += 1;
    const body = memoText(d.text ?? d.content ?? "");
    words += wordCount(body);
    for (const t of extractTags(d, body)) {
      if (t === "daily-note") continue; // 插件给 Daily Note 打的内部标签，不是主题
      tagCount.set(t, (tagCount.get(t) ?? 0) + 1);
    }
  }
  const tags = [...tagCount.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 10);
  return { tags, words, loaded, total: notes.length };
}

const tagItems = (tags: Array<[string, number]>) => tags.map(([t, c]) => `#${t}  ${c}`);

function todoSection(todos: TodoItem[], today: string, title = "待办"): string {
  if (todos.length === 0) return "";
  const when = (t: TodoItem) => [t.date, t.time].filter(Boolean).join(" ");
  const open = todos.filter((t) => !t.is_completed);
  const done = todos.filter((t) => t.is_completed);
  const lines = [
    ...open.map((t) => {
      const overdue = !!t.date && t.date < today;
      const meta = [when(t), overdue ? "已逾期" : ""].filter(Boolean).join("，");
      return `- [ ] ${t.content}${meta ? `（${meta}）` : ""}`;
    }),
    ...done.map((t) => `- [x] ${t.content}${t.time ? `（${t.time}）` : ""}`),
  ];
  return [`## ${title}`, "", ...lines].join("\n");
}

function analysisNote(c: ReturnType<typeof analyzeContent>): string {
  return c.total > 0 && c.loaded < c.total
    ? `> 正文分析进度 ${c.loaded}/${c.total}，其余笔记加载后会自动补全字数与标签。`
    : "";
}

// ── 单日概览（今天 / 昨天） ──

export function buildDayOverview(
  label: string,
  date: string,
  day: DayBucket | undefined,
  prevDay: DayBucket | undefined,
  prevLabel: string,
  details: Details,
  today: string,
): DetailDoc {
  const subtitle = `${date} ${weekdayName(new Date(`${date}T00:00:00`))}`;
  if (!day || (day.notes.length === 0 && day.todos.length === 0)) {
    return makeDoc({
      title: label,
      subtitle,
      sections: [
        "还没有记录。",
        prevDay ? `${prevLabel}有 ${prevDay.notes.length} 条笔记、${prevDay.todos.length} 个待办。` : "",
      ],
    });
  }

  const notes = [...day.notes].sort((a, b) => (a.created_at ?? "").localeCompare(b.created_at ?? ""));
  const todos = day.todos;
  const doneCount = todos.filter((t) => t.is_completed).length;
  const openCount = todos.length - doneCount;
  const content = analyzeContent(notes, details);
  const times = notes.map((n) => localHHmm(n.created_at)).filter(Boolean);
  const { rows: periods, peak } = periodRows(notes);

  const rows: DocItem[] = [
    { title: "笔记", text: `${notes.length} 条${delta(notes.length, prevDay?.notes.length, prevLabel)}` },
  ];
  if (todos.length > 0) {
    rows.push({ title: "待办", text: `${doneCount}/${todos.length} 完成` });
    rows.push({ title: "完成率", text: `${progress(doneCount, todos.length)} ${pct(doneCount, todos.length)}` });
  }
  if (content.loaded > 0) {
    rows.push({
      title: "字数",
      text: `约 ${content.words} 字，平均 ${Math.round(content.words / content.loaded)} 字/条`,
    });
  }
  if (times.length > 0) rows.push({ title: "记录时间", text: `${times[0]} - ${times[times.length - 1]}` });
  if (peak) rows.push({ title: "高峰时段", text: peak });
  if (periods.length > 0) rows.push(null, ...periods);

  const timeline = [
    "## 时间轴",
    "",
    ...notes.map((n) => {
      const summary = n.summary ? `　${truncate(n.summary.replace(/\s+/g, " "), 60)}` : "";
      return `- ${localHHmm(n.created_at)}　**${n.title}**${summary}`;
    }),
  ].join("\n");

  const insights: string[] = [];
  if (todos.length > 0 && openCount === 0) insights.push("今天的待办已全部完成");
  else if (openCount > 0) insights.push(`还有 ${openCount} 个待办未完成`);
  if (prevDay && notes.length > prevDay.notes.length) {
    insights.push(`记录比${prevLabel}更活跃（多 ${notes.length - prevDay.notes.length} 条）`);
  }
  if (content.tags[0]) insights.push(`出现最多的标签是 #${content.tags[0][0]}`);

  return makeDoc({
    title: label,
    subtitle,
    rows,
    tags: tagItems(content.tags),
    sections: [
      todoSection(todos, today),
      timeline,
      insights.length > 0 ? ["## 观察", "", ...insights.map((s) => `- ${s}`)].join("\n") : "",
      analysisNote(content),
    ],
  });
}

// ── 区间概览（最近 7 天 / 上周 / 本月…） ──

export function buildRangeOverview(data: TimelineData, details: Details, today = formatDate(new Date())): DetailDoc {
  const { days, range, previous } = data;
  const allNotes = days.flatMap((d) => d.notes);
  const allTodos = days.flatMap((d) => d.todos);

  const dayCount = Math.max(1, Math.round((range.end.getTime() - range.start.getTime()) / 86400000));
  const activeDays = days.filter((d) => d.notes.length > 0).length;
  const content = analyzeContent(allNotes, details);
  const { rows: periods, peak } = periodRows(allNotes);

  // 最长连续记录天数
  const noteDays = new Set(days.filter((d) => d.notes.length > 0).map((d) => d.date));
  let streak = 0;
  let best = 0;
  for (let i = 0; i < dayCount; i++) {
    const dt = new Date(range.start);
    dt.setDate(dt.getDate() + i);
    if (noteDays.has(formatDate(dt))) {
      streak += 1;
      best = Math.max(best, streak);
    } else streak = 0;
  }

  const rows: DocItem[] = [
    {
      title: "笔记",
      text: `${data.noteCount} 条，日均 ${(data.noteCount / dayCount).toFixed(1)} 条${delta(data.noteCount, previous?.noteCount, "上期")}`,
    },
  ];
  if (data.todoTotal > 0) {
    rows.push({ title: "待办", text: `${data.todoDone}/${data.todoTotal} 完成` });
    rows.push({
      title: "完成率",
      text: `${progress(data.todoDone, data.todoTotal)} ${pct(data.todoDone, data.todoTotal)}${compareRate(data, previous)}`,
    });
  }
  rows.push({ title: "活跃天数", text: `${activeDays}/${dayCount} 天，最长连续 ${best} 天` });
  if (content.loaded > 0) {
    rows.push({
      title: "字数",
      text: `约 ${content.words} 字，平均 ${Math.round(content.words / content.loaded)} 字/条`,
    });
  }
  if (peak) rows.push({ title: "高峰时段", text: peak });
  const trend = trendRows(data, dayCount);
  if (trend.length > 0) rows.push(null, ...trend);
  if (periods.length > 0) rows.push(null, ...periods);

  const openTodos = allTodos.filter((t) => !t.is_completed);
  const overdue = openTodos.filter((t) => t.date && t.date < today);
  const openSection =
    openTodos.length > 0
      ? todoSection(
          openTodos.slice(0, 12),
          today,
          `未完成待办（${openTodos.length}${overdue.length ? `，已逾期 ${overdue.length}` : ""}）`,
        ) + (openTodos.length > 12 ? `\n- 另有 ${openTodos.length - 12} 个` : "")
      : "";

  const insights: string[] = [];
  const busiest = [...days].sort((a, b) => b.notes.length - a.notes.length)[0];
  if (busiest && busiest.notes.length > 0) {
    insights.push(`记录最多的一天是 ${busiest.title}（${busiest.notes.length} 条）`);
  }
  if (previous) {
    const d = data.noteCount - previous.noteCount;
    if (d !== 0) insights.push(`笔记量比上期${d > 0 ? "增加" : "减少"} ${Math.abs(d)} 条`);
  }
  if (content.tags[0]) insights.push(`最常出现的主题是 #${content.tags[0][0]}`);
  if (dayCount <= 14 && dayCount - activeDays > 0) insights.push(`有 ${dayCount - activeDays} 天没有任何记录`);

  return makeDoc({
    title: range.label,
    subtitle: `${formatDate(range.start)} 至 ${formatDate(lastDayOf(range))}`,
    rows,
    tagsTitle: "标签榜",
    tags: tagItems(content.tags),
    sections: [
      openSection,
      insights.length > 0 ? ["## 观察", "", ...insights.map((s) => `- ${s}`)].join("\n") : "",
      analysisNote(content),
    ],
    copyOnly: [buildReport(data).replace(/^# .*\n/, "## 明细\n")],
  });
}

function compareRate(data: TimelineData, prev?: PrevStats): string {
  if (!prev || prev.todoTotal === 0 || data.todoTotal === 0) return "";
  const cur = Math.round((data.todoDone / data.todoTotal) * 100);
  const old = Math.round((prev.todoDone / prev.todoTotal) * 100);
  const d = cur - old;
  return d === 0 ? "　与上期持平" : `　较上期 ${d > 0 ? "+" : "-"}${Math.abs(d)}%`;
}

/** 趋势行：≤14 天按天，否则按周；title 为日期，text 为柱 + 笔记数 + 待办完成 */
function trendRows(data: TimelineData, dayCount: number): DocRow[] {
  const byDate = new Map(data.days.map((d) => [d.date, d]));
  type Row = { label: string; notes: number; done: number; total: number };
  const rows: Row[] = [];

  if (dayCount <= 14) {
    for (let i = 0; i < dayCount; i++) {
      const dt = new Date(data.range.start);
      dt.setDate(dt.getDate() + i);
      const key = formatDate(dt);
      const day = byDate.get(key);
      rows.push({
        label: `${key.slice(5)} ${weekdayName(dt)}`,
        notes: day?.notes.length ?? 0,
        done: day?.todos.filter((t) => t.is_completed).length ?? 0,
        total: day?.todos.length ?? 0,
      });
    }
  } else {
    const weeks = new Map<string, Row>();
    for (let i = 0; i < dayCount; i++) {
      const dt = new Date(data.range.start);
      dt.setDate(dt.getDate() + i);
      const monday = new Date(dt);
      monday.setDate(dt.getDate() - ((dt.getDay() + 6) % 7));
      const key = formatDate(monday);
      const row = weeks.get(key) ?? { label: `${key.slice(5)} 起`, notes: 0, done: 0, total: 0 };
      const day = byDate.get(formatDate(dt));
      row.notes += day?.notes.length ?? 0;
      row.done += day?.todos.filter((t) => t.is_completed).length ?? 0;
      row.total += day?.todos.length ?? 0;
      weeks.set(key, row);
    }
    rows.push(...[...weeks.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([, r]) => r));
  }

  const max = Math.max(...rows.map((r) => r.notes), 0);
  if (max === 0 && rows.every((r) => r.total === 0)) return [];
  return rows.map((r) => ({
    title: r.label,
    text: `${r.notes > 0 ? `${bar(r.notes, max)} ${r.notes}` : "-"}${r.total ? `　待办 ${r.done}/${r.total}` : ""}`,
  }));
}

/** 取某天的 bucket */
export const findDay = (data: TimelineData, date: string): DayBucket | undefined =>
  data.days.find((d) => d.date === date);
