import { createNote, createTodos } from "./api";
import { CaptureKind } from "./capture-parse";
import { appendToToday } from "./daily";
import { getDefaultTags, truncate } from "./utils";

export const KIND_LABEL: Record<CaptureKind, string> = { todo: "待办", daily: "Daily Note", note: "笔记" };

export const firstLine = (s: string) =>
  s
    .split(/\r?\n/)
    .find((l) => l.trim())
    ?.trim() ?? "";

export interface SavePlan {
  kind: CaptureKind;
  body: string;
  todo: { content: string; date?: string; time?: string };
  tags: string[];
  folderId?: string;
  /** 例如「 📁阅读笔记」，追加在提示末尾 */
  folderNote?: string;
  /** 例如「智能识别」「剪贴板」，空表示用户明确指定 */
  how?: string;
}

/** 按计划保存，返回给 HUD 的结果说明 */
export async function saveCapture(p: SavePlan): Promise<string> {
  const kindText = `${KIND_LABEL[p.kind]}${p.how ? `（${p.how}）` : ""}`;

  if (p.kind === "todo") {
    const { content, date, time } = p.todo;
    await createTodos([{ content, ...(date ? { date } : {}), ...(time ? { time } : {}) }]);
    const when = [date, time].filter(Boolean).join(" ");
    return `✅ ${kindText}：${truncate(content, 24)}${when ? `（${when}）` : ""}`;
  }

  if (p.kind === "daily") {
    const entry = [p.body, ...p.tags.map((t) => `#${t}`)].join(" ");
    await appendToToday(entry);
    return `✅ ${kindText}：${truncate(firstLine(p.body), 24)}`;
  }

  const title = truncate(firstLine(p.body), 30);
  const allTags = [...new Set([...getDefaultTags(), ...p.tags])];
  await createNote({
    title,
    body: p.body,
    tags: allTags.length > 0 ? allTags : undefined,
    folder: p.folderId,
    source: "tinycast",
  });
  return `✅ ${kindText}：${truncate(title, 24)}${p.tags.length ? ` ${p.tags.map((t) => `#${t}`).join(" ")}` : ""}${p.folderNote ?? ""}`;
}
