import { Clipboard, LaunchType, launchCommand, showHUD } from "@raycast/api";
import { warmUp } from "./api";
import { runCapture, SmartCaptureArgs } from "./capture-run";

/**
 * 万能输入（无界面）：
 *  - 搜索栏里带了文字 → 直接保存，完成后弹 HUD，不出现任何界面
 *  - 什么都没输入   → 打开「Smart Capture Form」表单（边输入边自动识别类型 / 标签 / 文件夹）
 */
export default async function Command(props: { arguments: SmartCaptureArgs }) {
  const args = props.arguments ?? {};
  const text = (args.text ?? "").trim();

  if (!text) {
    try {
      await launchCommand({ name: "capture-form", type: LaunchType.UserInitiated });
    } catch (error) {
      await showHUD(
        `打不开表单：${error instanceof Error ? error.message : String(error)}。请在设置 → 扩展里启用「Smart Capture Form」`,
      );
    }
    return;
  }

  warmUp();
  try {
    await showHUD(await runCapture(args));
  } catch (error) {
    await Clipboard.copy(text);
    await showHUD(`❌ 保存失败：${error instanceof Error ? error.message : String(error)}（内容已复制到剪贴板）`);
  }
}
