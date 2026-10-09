import { LocalStorage } from "@raycast/api";

/**
 * 菜单栏不能弹表单：菜单里点「记一条」等，先把意图存下来，再打开 Todos，
 * Todos 启动后读到就直接进入对应页面（一次性，超过 1 分钟作废）。
 */
export interface PendingOpen {
  action: "log" | "page" | "add";
  keyword?: string;
  at: number;
}

const KEY = "pending-open-v1";
const VALID_MS = 60 * 1000;

export async function setPendingOpen(
  p: Omit<PendingOpen, "at">,
): Promise<void> {
  await LocalStorage.setItem(KEY, JSON.stringify({ ...p, at: Date.now() }));
}

export async function takePendingOpen(): Promise<PendingOpen | undefined> {
  try {
    const raw = await LocalStorage.getItem<string>(KEY);
    if (!raw) return undefined;
    await LocalStorage.removeItem(KEY);
    const p = JSON.parse(raw) as PendingOpen;
    return Date.now() - p.at <= VALID_MS ? p : undefined;
  } catch {
    return undefined;
  }
}
