import { LocalStorage } from "@raycast/api";
import { FolderInfo, listFolders } from "./api";

const KEY = "folders-cache-v1";
/** 超过这个时间就在后台刷新（本次仍使用缓存，不阻塞保存） */
const STALE_MS = 10 * 60 * 1000;

interface Cached {
  at: number;
  list: FolderInfo[];
}

async function fetchAndStore(): Promise<FolderInfo[]> {
  const list = await listFolders();
  await LocalStorage.setItem(KEY, JSON.stringify({ at: Date.now(), list } satisfies Cached));
  return list;
}

/**
 * 文件夹列表：优先用本地缓存（0 次网络等待），过期时后台刷新；没有缓存才同步拉取。
 * 文件夹很少变动，保存时不值得为它多等一次往返。
 */
export async function getFoldersFast(): Promise<FolderInfo[]> {
  try {
    const raw = await LocalStorage.getItem<string>(KEY);
    if (raw) {
      const cached = JSON.parse(raw) as Cached;
      if (Array.isArray(cached.list)) {
        if (Date.now() - cached.at > STALE_MS) fetchAndStore().catch(() => {});
        return cached.list;
      }
    }
  } catch {
    // 缓存损坏：忽略，走网络
  }
  return fetchAndStore().catch(() => []);
}

/** 缓存里找不到用户指定的文件夹时，拉一次最新的再判断（可能是刚新建的） */
export async function getFoldersFresh(): Promise<FolderInfo[]> {
  return fetchAndStore().catch(() => []);
}
