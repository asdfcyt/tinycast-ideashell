import { isDidaConnected } from "./dida";
import { createRow } from "./todo-ops";
import { parseTodoInput } from "./todo-parse";

/**
 * 根搜索栏快速添加待办：解析日期 / 时间 / !重要，已连接滴答清单就建在滴答
 * （不带日期就是无日期任务，在「整理收集箱」里处理），否则建在闪念贝壳。返回给 HUD 的提示。
 */
export async function quickCreateTodo(raw: string): Promise<string> {
  const { content, date, time } = parseTodoInput(raw);
  const important = /[!！]重要/.test(content);
  const title = content.replace(/\s*[!！](?:重要|紧急)/g, "").trim() || content;
  const where = (await isDidaConnected()) ? "滴答清单" : "闪念贝壳";
  await createRow({ title, date, time, priority: important ? 5 : 0 });
  const when = date ? `${date}${time ? ` ${time}` : ""}` : "无日期，可在 Todos List 的「整理收集箱」处理";
  return `✅ 待办（${where}）：${title}（${when}）`;
}
