import { showHUD, showToast, Toast, LaunchProps } from "@raycast/api";
import { createTodos } from "./api";
import { parseTodoInput } from "./todo-parse";

interface AddTodoArgs {
  text: string;
}

export default async function Command(props: LaunchProps<{ arguments: AddTodoArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入待办内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建待办..." });

  try {
    const { content, date, time } = parseTodoInput(text);
    await createTodos([{ content, ...(date ? { date } : {}), ...(time ? { time } : {}) }]);

    toast.hide();
    const when = [date, time].filter(Boolean).join(" ");
    await showHUD(`✅ 已添加待办：${content}${when ? `（${when}）` : ""}`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "创建待办失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
