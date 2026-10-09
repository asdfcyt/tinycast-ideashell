import { LocalStorage } from "@raycast/api";
import { getNoteId } from "./api";
import { buildBrief, daysBetween, DossierData, DossierNote, loadDossier, monthlySeries, sparkline } from "./dossier";
import { DetailDoc } from "./detail-doc";
import { formatDate } from "./utils";

/** 项目状态：搁置的项目不再提醒 */
export type ProjectStatus = "active" | "short" | "long" | "paused";
export const STATUS_LABEL: Record<ProjectStatus, string> = {
  active: "进行中",
  short: "短期",
  long: "长期",
  paused: "搁置",
};
export const STATUS_ORDER: ProjectStatus[] = ["active", "short", "long", "paused"];

/** 项目（原关注项）：用户用关键词 / 标签钉住的一件事。「什么算这件事」完全由关键词定义，不做任何自动归类。 */
export interface WatchItem {
  keyword: string;
  addedAt: number;
  /** 超过这么多天没提及，就提示「该记一条了」 */
  staleDays: number;
  status: ProjectStatus;
  /** 用户手写的「下一步」 */
  next: string;
  /** 额外挂的标签（闪念贝壳里的标签）：关键词 + 这些标签一起定义「什么算这件事」 */
  tags: string[];
}

/** 项目的全部检索词：关键词 + 标签（去重） */
export function projectTerms(item: Pick<WatchItem, "keyword" | "tags">): string[] {
  const seen = new Set<string>();
  return [item.keyword, ...(item.tags ?? [])].filter((t) => {
    const k = t.trim().toLowerCase();
    if (!k || seen.has(k)) return false;
    seen.add(k);
    return true;
  });
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
      .map((x) => ({
        ...x,
        staleDays: Number(x.staleDays) > 0 ? Number(x.staleDays) : DEFAULT_STALE_DAYS,
        status: STATUS_ORDER.includes(x.status) ? x.status : "active",
        next: typeof x.next === "string" ? x.next : "",
        tags: Array.isArray(x.tags) ? x.tags.filter((t) => typeof t === "string" && t) : [],
      }));
  } catch {
    return [];
  }
}

async function writeWatchlist(list: WatchItem[]): Promise<void> {
  await LocalStorage.setItem(LIST_KEY, JSON.stringify(list));
  notify();
}

const cleanTags = (tags: string[]) => [...new Set(tags.map((t) => t.trim().replace(/^#+/, "")).filter(Boolean))];

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

export async function addWatch(keyword: string, tags: string[] = []): Promise<boolean> {
  const k = keyword.trim();
  if (!k) return false;
  const list = await loadWatchlist();
  if (list.some((x) => same(x.keyword, k))) return false;
  await writeWatchlist([
    ...list,
    {
      keyword: k,
      addedAt: Date.now(),
      staleDays: DEFAULT_STALE_DAYS,
      status: "active",
      next: "",
      tags: cleanTags(tags),
    },
  ]);
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

export async function setProjectStatus(keyword: string, status: ProjectStatus): Promise<void> {
  const list = await loadWatchlist();
  await writeWatchlist(list.map((x) => (same(x.keyword, keyword) ? { ...x, status } : x)));
}

export async function setProjectTags(keyword: string, tags: string[]): Promise<void> {
  const list = await loadWatchlist();
  await writeWatchlist(list.map((x) => (same(x.keyword, keyword) ? { ...x, tags: cleanTags(tags) } : x)));
  // 检索范围变了，旧统计作废，下次打开时后台重算
  const cache = await loadStatsCache();
  delete cache[keyword];
  await LocalStorage.setItem(STATS_KEY, JSON.stringify(cache));
}

export async function setProjectNext(keyword: string, next: string): Promise<void> {
  const list = await loadWatchlist();
  await writeWatchlist(list.map((x) => (same(x.keyword, keyword) ? { ...x, next: next.trim() } : x)));
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

/** 合并多个检索词的档案：笔记 / 待办 / 说话人按 id 去重，提及次数取各词之和 */
function mergeDossiers(item: WatchItem, datas: DossierData[], now: Date): DossierData {
  if (datas.length === 1) return datas[0];
  const notes = new Map<string, DossierNote>();
  for (const d of datas) {
    for (const n of d.notes) {
      const id = getNoteId(n.note);
      const old = notes.get(id);
      if (!old) notes.set(id, { ...n });
      else
        notes.set(id, {
          ...old,
          mentions: old.mentions + n.mentions,
          direct: old.direct || n.direct,
          viaSpeaker: old.viaSpeaker || n.viaSpeaker,
          snippet: n.mentions > old.mentions ? n.snippet : old.snippet,
          tags: [...new Set([...old.tags, ...n.tags])],
        });
    }
  }
  const mergedNotes = [...notes.values()].sort((a, b) =>
    (b.note.created_at ?? "").localeCompare(a.note.created_at ?? ""),
  );
  const todos = [...new Map(datas.flatMap((d) => d.todos).map((t) => [t.id, t])).values()].sort(
    (a, b) => Number(a.is_completed) - Number(b.is_completed) || (b.date ?? "").localeCompare(a.date ?? ""),
  );
  const speakers = [...new Map(datas.flatMap((d) => d.speakers).map((s) => [s.id, s])).values()];
  const direct = mergedNotes.filter((n) => n.direct);
  const q = `${item.keyword}（${(item.tags ?? []).map((t) => `#${t}`).join(" ")}）`;
  const doc = buildBrief({ q, notes: mergedNotes, direct, todos, speakers, now });
  return { query: q, notes: mergedNotes, directCount: direct.length, todos, speakers, doc, brief: doc.copy };
}

/** 重新统计一个项目并写入缓存（复用档案的检索与简报；关键词和标签各检索一次再合并） */
export async function computeStats(item: WatchItem, now = new Date()): Promise<WatchStats> {
  const datas: DossierData[] = [];
  for (const term of projectTerms(item)) datas.push(await loadDossier(term, now));
  const data = mergeDossiers(item, datas, now);
  const keyword = item.keyword;
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
