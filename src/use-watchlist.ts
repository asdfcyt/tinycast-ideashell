import { useCallback, useEffect, useRef, useState } from "react";
import {
  computeStats,
  loadStatsCache,
  loadWatchlist,
  STATS_TTL_MS,
  subscribeWatchlist,
  WatchItem,
  WatchStats,
} from "./watchlist";

/**
 * 关注项：先立刻显示本地缓存的统计，再在后台逐个重算过期（或强制刷新）的项目。
 * enabled=false 时只读列表，不发网络请求。
 */
export function useWatchlist(enabled: boolean, refreshTick: number) {
  const [items, setItems] = useState<WatchItem[]>([]);
  const [stats, setStats] = useState<Record<string, WatchStats>>({});
  const [computing, setComputing] = useState(false);
  const running = useRef(false);
  const lastTick = useRef(refreshTick);

  const sync = useCallback(
    async (force: boolean) => {
      const list = await loadWatchlist();
      const cache = await loadStatsCache();
      setItems(list);
      setStats(cache);
      if (!enabled || running.current) return;

      const due = list.filter((x) => force || !cache[x.keyword] || Date.now() - cache[x.keyword].at > STATS_TTL_MS);
      if (due.length === 0) return;
      running.current = true;
      setComputing(true);
      try {
        for (const item of due) {
          try {
            const s = await computeStats(item.keyword);
            setStats((prev) => ({ ...prev, [item.keyword]: s }));
          } catch {
            // 单项失败不影响其他项
          }
        }
      } finally {
        running.current = false;
        setComputing(false);
      }
    },
    [enabled],
  );

  useEffect(() => {
    const force = refreshTick !== lastTick.current;
    lastTick.current = refreshTick;
    sync(force);
    return subscribeWatchlist(() => {
      sync(false);
    });
  }, [sync, refreshTick]);

  return { items, stats, computing };
}
