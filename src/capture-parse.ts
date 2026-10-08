import { FolderInfo } from "./api";
import { parseTodoInput } from "./todo-parse";
import { formatDate } from "./utils";

export type CaptureKind = "todo" | "daily" | "note";

export interface CaptureAnalysis {
  body: string; // 去掉 #标签 / @文件夹 后的正文
  tags: string[];
  folderName?: string;
  todo: { content: string; date?: string; time?: string };
  recommended: CaptureKind;
}

const TODO_PREFIX = /^(?:待办|todo|提醒我?)(?:\s*[:：,，]\s*|\s+)/i;

/**
 * 分析万能输入：
 * - `#标签`、`@文件夹` 会被抽出（要求前面是行首或空白，避免误伤 C#、邮箱）
 * - 待办：以「待办/todo/提醒」开头，或含「今天及以后的明确时间」/「明天及以后的日期」
 * - 笔记：带标签/文件夹、多行、或超过 100 字
 * - 其余短句：追加到 Daily Note
 */
export function analyzeCapture(input: string, now = new Date()): CaptureAnalysis {
  const tags: string[] = [];
  let folderName: string | undefined;

  let body = input
    .replace(/(^|\s)#([^\s#@]+)/g, (_m, sp: string, t: string) => {
      tags.push(t);
      return sp;
    })
    .replace(/(^|\s)@([^\s#@]+)/g, (_m, sp: string, f: string) => {
      folderName ??= f;
      return sp;
    })
    .replace(/[ \t]{2,}/g, " ")
    .trim();

  const prefixed = TODO_PREFIX.test(body);
  const todoSource = prefixed ? body.replace(TODO_PREFIX, "") : body;
  const todo = parseTodoInput(todoSource, now);

  const today = formatDate(now);
  const futureCue = !!todo.date && todo.date >= today && (!!todo.time || todo.date > today);

  let recommended: CaptureKind;
  if (prefixed || futureCue) recommended = "todo";
  else if (tags.length > 0 || folderName || body.length > 100 || body.includes("\n")) recommended = "note";
  else recommended = "daily";

  return { body, tags: [...new Set(tags)], folderName, todo, recommended };
}

/** 按名称找文件夹：完全相同 → 忽略大小写/空格/末尾 s → 包含 */
export function matchFolder(name: string | undefined, folders: FolderInfo[]): FolderInfo | undefined {
  if (!name) return undefined;
  const norm = (s: string) =>
    s
      .toLowerCase()
      .replace(/[\s_\-·]+/g, "")
      .replace(/s$/, "");
  const n = norm(name);
  return (
    folders.find((f) => f.name.toLowerCase() === name.toLowerCase()) ||
    folders.find((f) => norm(f.name) === n) ||
    folders.find((f) => norm(f.name).includes(n))
  );
}
