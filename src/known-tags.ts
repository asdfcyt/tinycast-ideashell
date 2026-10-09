import { LocalStorage } from "@raycast/api";
import { getNoteDetail, getNoteId, getNotesInRange } from "./api";
import { extractTags } from "./note-text";
import { getDefaultTags } from "./utils";

/**
 * 闪念贝壳里已用过的标签（用于选标签时的候选项）。
 * 接口没有「列出所有标签」，这里从最近半年的笔记里统计，结果缓存 12 小时，可随时丢弃重建。
 */
const KEY = "known-tags-v1";
const TTL_MS = 12 * 3600 * 1000;
const LOOKBACK_DAYS = 180;
const MAX_NOTES = 120;

interface Cache {
  at: number;
  tags: Array<[string, number]>;
}

async function readCache(): Promise<Cache | null> {
  try {
    const raw = await LocalStorage.getItem<string>(KEY);
    return raw ? (JSON.parse(raw) as Cache) : null;
  } catch {
    return null;
  }
}

/** 先取缓存（可能为空）；过期或没有缓存时需要调用 refreshKnownTags */
export async function loadKnownTagsCached(): Promise<{ tags: string[]; stale: boolean }> {
  const c = await readCache();
  const base = [...getDefaultTags(), "摘录", "收藏", "复盘"];
  const tags = [...new Set([...(c?.tags.map(([t]) => t) ?? []), ...base])];
  return { tags, stale: !c || Date.now() - c.at > TTL_MS };
}

export async function refreshKnownTags(): Promise<string[]> {
  const end = new Date();
  const start = new Date(end.getTime() - LOOKBACK_DAYS * 86400000);
  const { notes } = await getNotesInRange(start, end);
  const ids = notes.slice(0, MAX_NOTES).map(getNoteId).filter(Boolean);

  const count = new Map<string, number>();
  const queue = [...ids];
  const worker = async () => {
    for (let id = queue.shift(); id; id = queue.shift()) {
      try {
        const d = await getNoteDetail(id);
        for (const t of extractTags(d, d.content ?? d.body ?? "")) count.set(t, (count.get(t) ?? 0) + 1);
      } catch {
        // 单条失败忽略
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(6, queue.length) }, worker));

  const tags = [...count.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  await LocalStorage.setItem(KEY, JSON.stringify({ at: Date.now(), tags } satisfies Cache));
  return (await loadKnownTagsCached()).tags;
}
