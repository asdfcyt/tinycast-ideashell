import { Clipboard, LaunchProps, launchCommand, LaunchType, showHUD } from "@raycast/api";
import { warmUp } from "./api";
import { runCapture, SmartCaptureArgs } from "./capture-run";

/**
 * 无界面命令：回车后窗口立即消失，保存完成弹 HUD，全程没有任何页面。
 * 什么都没输入时，打开 Template Capture 的「自由输入」表单（Tinycast 不支持隐藏命令，所以借用已有命令）。
 */
export default async function Command(props: LaunchProps<{ arguments: SmartCaptureArgs }>) {
  const text = props.arguments?.text?.trim() ?? "";

  if (!text) {
    try {
      await launchCommand({
        name: "template-capture",
        type: LaunchType.UserInitiated,
        arguments: { name: "自由输入" },
      });
    } catch {
      await showHUD("请输入内容后回车；或打开 Template Capture，选「自由输入」");
    }
    return;
  }

  warmUp();
  try {
    await showHUD(await runCapture({ ...props.arguments, text }));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await Clipboard.copy(text);
    await showHUD(`保存失败：${msg}（内容已复制到剪贴板）`);
  }
}
