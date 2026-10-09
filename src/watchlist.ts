import { LocalStorage } from "@raycast/api";
import { daysBetween, loadDossier, monthlySeries, sparkline } from "./dossier";
import { DetailDoc } from "./detail-doc";
import { formatDate } from "./utils";

/** 关注项：用户用关键词 / 标签钉住的一件事。「什么算这件事」完全由关键词定义，不做任何自动归类。 */
export interface WatchItem {
  keyword: string;
  addedAt: number;
  /** 超过这么多天没提及，就提示「该记一条了」 */
  staleDays: number;
}

/** 关注项的统计（可随时丢弃重建） */
export interface WatchStats {
  keyword: string;
  /** 统计时间（毫秒） */
  at: number;
  /** 最近一次提及的日期 YYYY-MM-DD，没有记录为空 */
  lastDay: string;
  lastTitle: string;
  count30: number;
  total: number;
  /** 近 12 个月每月提及的笔记数 */
  series: number[];
  doc: DetailDoc;
}

export const DEFAULT_STALE_DAYS = 7;
export const STALE_CHOICES = [3, 7, 14, 30, 60];
/** 统计结果的有效期，过期后在后台重算 */
export const STATS_TTL_MS = 6 * 3600 * 1000;

const LIST_KEY = "watchlist-v1";
const STATS_KEY = "watch-stats-v1";

const listeners = new Set<() => void>();
export function subscribeWatchlist(cb: () => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}
const notify = () => listeners.forEach((cb) => cb());

export async function loadWatchlist(): Promise<WatchItem[]> {
  try {
    const raw = await LocalStorage.getItem<string>(LIST_KEY);
    const list = raw ? (JSON.parse(raw) as WatchItem[]) : [];
    return list
      .filter((x) => x?.keyword)
      .map((x) => ({ ...x, staleDays: Number(x.staleDays) > 0 ? Number(x.staleDays) : DEFAULT_STALE_DAYS }));
  } catch {
    return [];
  }
}

async function writeWatchlist(list: WatchItem[]): Promise<void> {
  await LocalStorage.setItem(LIST_KEY, JSON.stringify(list));
  notify();
}

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

export async function addWatch(keyword: string): Promise<boolean> {
  const k = keyword.trim();
  if (!k) return false;
  const list = await loadWatchlist();
  if (list.some((x) => same(x.keyword, k))) return false;
  await writeWatchlist([...list, { keyword: k, addedAt: Date.now(), staleDays: DEFAULT_STALE_DAYS }]);
  return true;
}

export async function removeWatch(keyword: string): Promise<void> {
  const list = await loadWatchlist();
  await writeWatchlist(list.filter((x) => !same(x.keyword, keyword)));
  const cache = await loadStatsCache();
  delete cache[keyword];
  await LocalStorage.setItem(STATS_KEY, JSON.stringify(cache));
}

export async function setStaleDays(keyword: string, days: number): Promise<void> {
  const list = await loadWatchlist();
  await writeWatchlist(list.map((x) => (same(x.keyword, keyword) ? { ...x, staleDays: days } : x)));
}

export async function isWatched(keyword: string): Promise<boolean> {
  return (await loadWatchlist()).some((x) => same(x.keyword, keyword));
}

export async function loadStatsCache(): Promise<Record<string, WatchStats>> {
  try {
    const raw = await LocalStorage.getItem<string>(STATS_KEY);
    return raw ? (JSON.parse(raw) as Record<string, WatchStats>) : {};
  } catch {
    return {};
  }
}

/** 重新统计一个关注项并写入缓存（复用档案的检索与简报） */
export async function computeStats(keyword: string, now = new Date()): Promise<WatchStats> {
  const data = await loadDossier(keyword, now);
  const days = data.notes.filter((n) => n.direct && n.day);
  const today = formatDate(now);
  const stats: WatchStats = {
    keyword,
    at: Date.now(),
    lastDay: days[0]?.day ?? "",
    lastTitle: days[0]?.note.title ?? "",
    count30: days.filter((n) => daysBetween(n.day, today) <= 30).length,
    total: days.length,
    series: monthlySeries(
      days.map((n) => n.day),
      now,
    ).counts,
    doc: data.doc,
  };
  const cache = await loadStatsCache();
  cache[keyword] = stats;
  await LocalStorage.setItem(STATS_KEY, JSON.stringify(cache));
  return stats;
}

export { sparkline };
