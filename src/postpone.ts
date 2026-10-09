import { LocalStorage } from "@raycast/api";

/**
 * 推迟计数：同一个任务被推迟到之后的日期多次，往往说明任务太大或目的不清，
 * 提示用户拆解、补写「交付成果」。只存在本地，可随时丢弃。
 */
const KEY = "postpone-counts-v1";
export const POSTPONE_WARN = 3;

export async function loadPostpones(): Promise<Record<string, number>> {
  try {
    const raw = await LocalStorage.getItem<string>(KEY);
    return raw ? (JSON.parse(raw) as Record<string, number>) : {};
  } catch {
    return {};
  }
}

export async function bumpPostpone(taskKey: string): Promise<void> {
  const map = await loadPostpones();
  map[taskKey] = (map[taskKey] ?? 0) + 1;
  await LocalStorage.setItem(KEY, JSON.stringify(map));
}

export async function clearPostpone(taskKey: string): Promise<void> {
  const map = await loadPostpones();
  if (!(taskKey in map)) return;
  delete map[taskKey];
  await LocalStorage.setItem(KEY, JSON.stringify(map));
}
