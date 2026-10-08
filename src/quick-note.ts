import { showHUD, showToast, Toast, LaunchProps } from "@raycast/api";
import { createNote } from "./api";
import { getDefaultTags, truncate } from "./utils";

interface QuickNoteArgs {
  text: string;
}

export default async function Command(props: LaunchProps<{ arguments: QuickNoteArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建笔记..." });

  try {
    const title = truncate(text.trim(), 30);
    const body = text.trim();
    const tags = getDefaultTags();

    await createNote({
      title,
      body,
      tags: tags.length > 0 ? tags : undefined,
    });

    toast.hide();
    await showHUD(`✅ 已添加到闪念贝壳: ${truncate(text, 20)}`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "创建失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
