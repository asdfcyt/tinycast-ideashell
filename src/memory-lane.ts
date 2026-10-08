import { getNotesInRange, getNoteId, NoteInfo } from "./api";
import { localDay } from "./timeline-data";
import { formatDate } from "./utils";

/** 往日同期：日历推算，没有任何猜测 */
export interface SameDayGroup {
  label: string; // 1 个月前的今天
  date: string; // YYYY-MM-DD
  notes: NoteInfo[];
}

export interface MemoryData {
  /** 回溯范围内的全部笔记（随机抽取的候选池） */
  pool: NoteInfo[];
  sameDay: SameDayGroup[];
  truncated: boolean;
}

/** 回溯 5 年（笔记总量不大，空区间只需 1 次请求） */
const LOOKBACK_YEARS = 5;

type Offset = { label: string; shift: (d: Date) => Date };

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

/** 往前推 n 个月；目标月没有该日（如 31 号）时顺延到当月最后一天 */
function addMonths(d: Date, n: number): Date {
  const day = d.getDate();
  const x = new Date(d.getFullYear(), d.getMonth() + n, 1);
  const last = new Date(x.getFullYear(), x.getMonth() + 1, 0).getDate();
  x.setDate(Math.min(day, last));
  return x;
}

const OFFSETS: Offset[] = [
  { label: "1 周前的今天", shift: (d) => addDays(d, -7) },
  { label: "2 周前的今天", shift: (d) => addDays(d, -14) },
  { label: "1 个月前的今天", shift: (d) => addMonths(d, -1) },
  { label: "2 个月前的今天", shift: (d) => addMonths(d, -2) },
  { label: "3 个月前的今天", shift: (d) => addMonths(d, -3) },
  { label: "6 个月前的今天", shift: (d) => addMonths(d, -6) },
  ...Array.from({ length: LOOKBACK_YEARS }, (_, i) => ({
    label: `${i + 1} 年前的今天`,
    shift: (d: Date) => addMonths(d, -12 * (i + 1)),
  })),
];

export function isDailyNote(note: NoteInfo): boolean {
  return /^\d{4}-\d{2}-\d{2}/.test(note.title ?? "") || (note.tags ?? []).includes("daily-note");
}

export async function loadMemory(): Promise<MemoryData> {
  const now = new Date();
  const start = new Date(now.getFullYear() - LOOKBACK_YEARS, now.getMonth(), now.getDate());
  const { notes, truncated } = await getNotesInRange(start, new Date(now.getTime() + 60_000));

  const byDay = new Map<string, NoteInfo[]>();
  for (const n of notes) {
    const day = localDay(n.created_at);
    if (!day) continue;
    byDay.set(day, [...(byDay.get(day) ?? []), n]);
  }

  const seen = new Set<string>();
  const sameDay: SameDayGroup[] = [];
  for (const o of OFFSETS) {
    const date = formatDate(o.shift(now));
    if (seen.has(date)) continue; // 两个偏移落在同一天（如月末）时只保留靠前的
    seen.add(date);
    const list = byDay.get(date);
    if (list?.length) {
      sameDay.push({
        label: o.label,
        date,
        notes: [...list].sort((a, b) => (a.created_at || "").localeCompare(b.created_at || "")),
      });
    }
  }

  return { pool: notes.filter((n) => !isDailyNote(n)), sameDay, truncated };
}

/** 从候选池里随机抽一条（避开 avoid 里的 id；避不开时才放宽，保证有结果） */
export function pickRandom(pool: NoteInfo[], avoid: string[] = []): NoteInfo | null {
  const skip = new Set(avoid);
  const fresh = pool.filter((n) => !skip.has(getNoteId(n)));
  const candidates = fresh.length > 0 ? fresh : pool;
  if (candidates.length === 0) return null;
  return candidates[Math.floor(Math.random() * candidates.length)];
}

/** 往日同期里出现过的笔记 id（随机一条不与之重复，避免列表里出现两个相同条目） */
export function sameDayIds(data: MemoryData): string[] {
  return data.sameDay.flatMap((g) => g.notes.map(getNoteId));
}
