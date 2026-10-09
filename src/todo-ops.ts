import { createTodos, updateTodos } from "./api";
import { isDidaConnected, loadMap, pushCompleteToDida, saveMap } from "./dida";
import { completeDidaTask, createDidaTask, patchDidaTask } from "./dida-tasks";
import { TodoRow } from "./todo-data";
import { toggleMark } from "./todo-meta";

/** 完成一行待办：滴答行完成滴答任务（并带上对应的闪念贝壳待办），闪念贝壳行完成后推给滴答 */
export async function completeRow(row: TodoRow): Promise<void> {
  if (row.source === "dida") {
    await completeDidaTask(row);
    if (row.ideaId) {
      await updateTodos([{ todo_id: row.ideaId, is_completed: true }]);
      const map = await loadMap();
      if (map[row.ideaId]) {
        map[row.ideaId].done = true;
        await saveMap(map);
      }
    }
    return;
  }
  await updateTodos([{ todo_id: row.id, is_completed: true }]);
  await pushCompleteToDida(row.id);
}

export async function restoreRow(row: TodoRow): Promise<void> {
  if (row.source === "dida") {
    await patchDidaTask(row, { status: 0 });
    if (row.ideaId)
      await updateTodos([{ todo_id: row.ideaId, is_completed: false }]);
    return;
  }
  await updateTodos([{ todo_id: row.id, is_completed: false }]);
}

export interface RowPatch {
  title?: string;
  date?: string;
  time?: string;
  priority?: number;
  /** 改成全天任务（去掉具体时间） */
  allDay?: boolean;
  content?: string;
  tags?: string[];
}

/** 修改一行待办：滴答行改滴答任务，闪念贝壳行改闪念贝壳待办（之后会同步到滴答） */
export async function patchRow(row: TodoRow, patch: RowPatch): Promise<void> {
  if (row.source === "dida") {
    // 滴答的日期和时间合在一个字段里：只改时间也要带上原日期，只改日期则保留原时间
    const date =
      patch.date ?? (patch.time || patch.allDay ? row.date : undefined);
    await patchDidaTask(row, {
      title: patch.title,
      content: patch.content,
      priority: patch.priority,
      tags: patch.tags,
      date,
      time: date
        ? patch.allDay
          ? undefined
          : (patch.time ?? row.time)
        : undefined,
    });
    return;
  }
  const marks = (row.rawTitle.match(/\s*[!！](?:重要|紧急)/g) ?? []).join("");
  let content =
    patch.title !== undefined ? `${patch.title}${marks}` : row.rawTitle;
  if (patch.priority !== undefined && patch.priority >= 3 !== row.priority >= 3)
    content = toggleMark(content, "重要");
  await updateTodos([
    {
      todo_id: row.id,
      ...(content !== row.rawTitle ? { content } : {}),
      ...(patch.date ? { date: patch.date } : {}),
      ...(patch.time ? { time: patch.time } : {}),
    },
  ]);
}

/** 新建待办：已连接滴答就直接建在滴答里（核心在滴答），否则建在闪念贝壳 */
export async function createRow(f: {
  title: string;
  date?: string;
  time?: string;
  priority?: number;
  tags?: string[];
}): Promise<"dida" | "idea"> {
  if (await isDidaConnected()) {
    await createDidaTask({
      title: f.title,
      date: f.date,
      time: f.time,
      priority: f.priority,
      tags: f.tags,
    });
    return "dida";
  }
  await createTodos([
    {
      content:
        f.priority && f.priority >= 3 ? toggleMark(f.title, "重要") : f.title,
      ...(f.date ? { date: f.date } : {}),
      ...(f.time ? { time: f.time } : {}),
    },
  ]);
  return "idea";
}
