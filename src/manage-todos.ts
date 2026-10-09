import { Clipboard, LaunchProps, launchCommand, LaunchType, showHUD } from "@raycast/api";
import { warmUp } from "./api";
import { quickCreateTodo } from "./quick-create";

/**
 * 无界面入口：有内容 → 回车后窗口立即消失，直接创建待办并弹 HUD（和 Smart Capture 一样不闪窗）；
 * 什么都没输入 → 打开待办列表（Todos List）。
 */
export default async function Command(props: LaunchProps<{ arguments: { text?: string } }>) {
  const raw = props.arguments?.text?.trim() ?? "";

  if (!raw) {
    try {
      await launchCommand({ name: "todos-list", type: LaunchType.UserInitiated });
    } catch {
      await showHUD("请在根搜索里打开「Todos List」");
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
