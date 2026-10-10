import {
  Clipboard,
  environment,
  LaunchProps,
  launchCommand,
  LaunchType,
  LocalStorage,
  showHUD,
} from "@raycast/api";
import { warmUp } from "./api";
import { TODOS_LIST_QUERY } from "./entry-flags";
import { quickCreateTodo } from "./quick-create";
import { refreshSummaryInBackground } from "./todo-summary";

/**
 * 无界面入口：有内容 → 回车后窗口立即消失，直接创建待办并弹 HUD（和 Smart Capture 一样不闪窗）；
 * 什么都没输入 → 打开待办列表（由 Notes 命令承载，不再有单独的 Todos List 命令）。
 * 后台定时运行（interval）时：只刷新根搜索里本命令的副标题（今天 N · 逾期 M · 下一个 …），不弹任何东西。
 */
export default async function Command(
  props: LaunchProps<{ arguments: { text?: string } }>,
) {
  await LocalStorage.setItem(
    "summary-run-v1",
    JSON.stringify({ at: Date.now(), type: String(environment.launchType) }),
  ).catch(() => undefined);
  if (environment.launchType === LaunchType.Background) {
    const t0 = Date.now();
    let err = "";
    try {
      await refreshSummaryInBackground();
    } catch (e) {
      // 后台刷新失败就保持旧的副标题，下次再试；原因记下来方便排查
      err = e instanceof Error ? e.message : String(e);
    }
    await LocalStorage.setItem(
      "summary-bg-log-v1",
      JSON.stringify({ at: t0, ms: Date.now() - t0, err }),
    ).catch(() => undefined);
    return;
  }

  // 上一版（有界面 + 关窗）被终止时遗留的待建内容，补建一次
  const left = await LocalStorage.getItem<string>("pending-todo-v1");
  if (left) {
    await LocalStorage.removeItem("pending-todo-v1");
    try {
      await quickCreateTodo(left);
    } catch {
      await Clipboard.copy(left);
    }
  }

  const raw = props.arguments?.text?.trim() ?? "";

  if (!raw) {
    try {
      await launchCommand({
        name: "notes",
        type: LaunchType.UserInitiated,
        arguments: { query: TODOS_LIST_QUERY },
      });
    } catch {
      await showHUD("打开待办列表失败");
    }
    return;
  }

  warmUp();
  try {
    await showHUD(await quickCreateTodo(raw));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await Clipboard.copy(raw);
    await showHUD(`创建失败：${msg}（内容已复制到剪贴板）`);
  }
}
