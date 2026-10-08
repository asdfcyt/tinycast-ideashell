import { showHUD, showToast, Toast, LaunchProps } from "@raycast/api";
import { appendToToday } from "./daily";

interface DailyNoteArgs {
  text: string;
}

export default async function Command(props: LaunchProps<{ arguments: DailyNoteArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在追加到 Daily Note..." });

  try {
    await appendToToday(text);
    toast.hide();
    await showHUD(`✅ 已追加到 Daily Note: ${text.trim().slice(0, 20)}`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "追加失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
