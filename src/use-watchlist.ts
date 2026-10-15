import { useCallback, useEffect, useRef, useState } from "react";
import { autoImportPhoneBackup } from "./backup-import";
import { discoverProjects } from "./task-notes";
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
/** 每次打开命令只自动发现一次：闪念贝壳里已有的「项目主页」笔记（比如手机上建的项目）自动成为项目 */
let discovering: Promise<number> | undefined;

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
            const s = await computeStats(item);
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
    if (!enabled || discovering) return;
    // 先静默导入手机备份（项目、任务笔记、项目主页），再从笔记里自动发现项目
    discovering = autoImportPhoneBackup()
      .then(async (a) => a + (await discoverProjects()))
      .catch(() => 0);
    discovering.then((n) => {
      if (n > 0) sync(false);
    });
  }, [enabled, sync]);

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
