import { callDida } from "./dida";
import { collectObjects, isoLocal, parseAny, saveSample, startOfDay } from "./dida-tasks";

/**
 * 滴答清单的专注（番茄钟 / 正计时）记录。滴答 MCP 只能读 / 写记录，不能启动计时：
 * 计时在滴答里进行，这里读回来显示「今日 / 近 7 天专注了多久」。
 */

export interface TaskFocus {
  todayMin: number;
  todayCount: number;
  weekMin: number;
  weekCount: number;
}

export interface FocusSummary {
  todayMin: number;
  todayPomos: number;
  weekMin: number;
  weekPomos: number;
  byTask: Record<string, TaskFocus>;
  titles: Record<string, string>;
}

/** `2026-10-09T10:00:00+0800` → 毫秒（部分 JS 引擎不认没有冒号的时区偏移，先补上） */
function parseTime(v: unknown): number | null {
  if (typeof v !== "string") return null;
  const t = Date.parse(v.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
  return Number.isNaN(t) ? null : t;
}

const empty = (): TaskFocus => ({ todayMin: 0, todayCount: 0, weekMin: 0, weekCount: 0 });

export const emptyFocus = (): FocusSummary => ({
  todayMin: 0,
  todayPomos: 0,
  weekMin: 0,
  weekPomos: 0,
  byTask: {},
  titles: {},
});

/** 读取近 7 天（含今天）的专注记录并汇总 */
export async function fetchFocusSummary(now = new Date()): Promise<FocusSummary> {
  const from = startOfDay(now, -6);
  const todayStart = startOfDay(now).getTime();
  const args = (type: number) => ({
    from_time: isoLocal(from),
    to_time: isoLocal(startOfDay(now, 1)),
    type,
  });
  const [pomo, timing] = await Promise.allSettled([
    callDida("get_focuses_by_time", args(0)),
    callDida("get_focuses_by_time", args(1)),
  ]);
  if (pomo.status === "rejected" && timing.status === "rejected") throw pomo.reason;

  const sum = emptyFocus();
  const seen = new Set<string>();
  const texts = [
    ["pomo", pomo],
    ["timing", timing],
  ] as const;
  for (const [kind, r] of texts) {
    const text = r.status === "fulfilled" ? r.value : "";
    await saveSample(`focus_${kind}`, text);
    const found: Record<string, unknown>[] = [];
    collectObjects(parseAny(text), (o) => typeof o.startTime === "string" && typeof o.endTime === "string", found);
    for (const o of found) {
      const start = parseTime(o.startTime);
      const end = parseTime(o.endTime);
      if (start === null || end === null || end <= start) continue;
      const id = typeof o.id === "string" ? o.id : `${kind}-${start}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const minutes = Math.round((end - start) / 60000);
      const isToday = start >= todayStart;
      const isPomo = kind === "pomo";
      sum.weekMin += minutes;
      if (isPomo) sum.weekPomos++;
      if (isToday) {
        sum.todayMin += minutes;
        if (isPomo) sum.todayPomos++;
      }
      // 关联的任务：taskId 或 tasks[] 里的简要信息
      const ids = new Set<string>();
      if (typeof o.taskId === "string" && o.taskId) ids.add(o.taskId);
      if (Array.isArray(o.tasks)) {
        for (const t of o.tasks) {
          if (!t || typeof t !== "object") continue;
          const b = t as Record<string, unknown>;
          const tid = typeof b.taskId === "string" ? b.taskId : typeof b.id === "string" ? b.id : "";
          if (!tid) continue;
          ids.add(tid);
          if (typeof b.title === "string" && b.title) sum.titles[tid] = b.title;
        }
      }
      for (const tid of ids) {
        const f = (sum.byTask[tid] ??= empty());
        f.weekMin += minutes;
        f.weekCount++;
        if (isToday) {
          f.todayMin += minutes;
          f.todayCount++;
        }
      }
    }
  }
  return sum;
}

export function formatMinutes(min: number): string {
  if (min < 60) return `${min} 分钟`;
  const h = Math.floor(min / 60);
  const m = min % 60;
  return m ? `${h} 小时 ${m} 分钟` : `${h} 小时`;
}
