import { daysBetween } from "./dossier";
import { formatDate } from "./utils";
import {
  computeStats,
  loadStatsCache,
  loadWatchlist,
  STATUS_ORDER,
  WatchItem,
  WatchStats,
} from "./watchlist";

/** 菜单栏里的一个项目：距上次提及的天数、是否该推进了 */
export interface ProjectMenuRow {
  item: WatchItem;
  /** 距上次提及的天数；没有记录为 null */
  gap: number | null;
  stale: boolean;
}

/** 统计超过这么久，且被判为「该推进」的项目，才在菜单里重新统计一遍（避免白提醒） */
const RECHECK_MS = 30 * 60 * 1000;

export function buildProjectRows(
  items: WatchItem[],
  stats: Record<string, WatchStats>,
  today = formatDate(new Date()),
): ProjectMenuRow[] {
  const rows = items.map((item, index) => {
    const lastDay = stats[item.keyword]?.lastDay;
    const gap = lastDay ? daysBetween(lastDay, today) : null;
    return {
      item,
      gap,
      stale: item.status !== "paused" && gap !== null && gap >= item.staleDays,
      index,
    };
  });
  const rank = (r: (typeof rows)[number]) =>
    r.stale ? 0 : r.item.status === "paused" ? 3 : 1;
  rows.sort(
    (a, b) =>
      rank(a) - rank(b) ||
      (a.stale && b.stale ? (b.gap ?? 0) - (a.gap ?? 0) : 0) ||
      STATUS_ORDER.indexOf(a.item.status) -
        STATUS_ORDER.indexOf(b.item.status) ||
      a.index - b.index,
  );
  return rows.map(({ item, gap, stale }) => ({ item, gap, stale }));
}

/** 读本地缓存，立即可用（不发网络请求） */
export async function readProjectRows(): Promise<ProjectMenuRow[]> {
  const [items, stats] = await Promise.all([loadWatchlist(), loadStatsCache()]);
  return buildProjectRows(items, stats);
}

/**
 * 缓存里判为「该推进」的项目，如果统计已经有点旧，就重新统计一次
 * （缓存可能是在你写了新笔记之前算的）。没有变化返回 undefined。
 */
export async function recheckStaleProjects(): Promise<
  ProjectMenuRow[] | undefined
> {
  const [items, stats] = await Promise.all([loadWatchlist(), loadStatsCache()]);
  const rows = buildProjectRows(items, stats);
  const due = rows.filter(
    (r) =>
      r.stale && Date.now() - (stats[r.item.keyword]?.at ?? 0) > RECHECK_MS,
  );
  if (due.length === 0) return undefined;
  for (const r of due) {
    try {
      stats[r.item.keyword] = await computeStats(r.item);
    } catch {
      // 单项失败不影响其他项
    }
  }
  return buildProjectRows(items, stats);
}
