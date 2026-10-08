import { FolderInfo } from "./api";
import { parseTodoInput } from "./todo-parse";
import { formatDate } from "./utils";

export type CaptureKind = "todo" | "daily" | "note";

export interface CaptureAnalysis {
  /** 去掉强制前缀后的原文（保留 #标签 / @文件夹），追加到 Daily Note 时使用 */
  text: string;
  /** 再去掉 #标签 / @文件夹 后的正文，笔记和待办使用 */
  body: string;
  tags: string[];
  folderName?: string;
  todo: { content: string; date?: string; time?: string };
  /** 用户用前缀明确指定的类型 */
  forced?: CaptureKind;
  /** 自动判断的类型 */
  recommended: CaptureKind;
}

const SEP = "(?:\\s*[:：,，]\\s*|\\s+)";
const PREFIXES: Array<[RegExp, CaptureKind]> = [
  [new RegExp(`^(?:待办|todo|提醒我?)${SEP}`, "i"), "todo"],
  [new RegExp(`^(?:日记|daily)${SEP}`, "i"), "daily"],
  [new RegExp(`^(?:笔记|note)${SEP}`, "i"), "note"],
];

/**
 * 分析万能输入：
 * - 前缀强制类型：`待办 …` / `todo …` / `提醒我 …`、`日记 …` / `daily …`、`笔记 …` / `note …`
 * - `#标签`、`@文件夹` 会被抽出（要求前面是行首或空白，避免误伤 C#、邮箱）
 * - 自动判断：
 *   待办 = 含「今天及以后的明确时间」或「明天及以后的日期」
 *   笔记 = 带标签/文件夹、多行、或超过 100 字
 *   其余短句 = 追加到 Daily Note
 */
export function analyzeCapture(input: string, now = new Date()): CaptureAnalysis {
  let text = input.trim();
  let forced: CaptureKind | undefined;
  for (const [re, kind] of PREFIXES) {
    if (re.test(text)) {
      forced = kind;
      text = text.replace(re, "").trim();
      break;
    }
  }

  const tags: string[] = [];
  let folderName: string | undefined;

  const body = text
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

  const todo = parseTodoInput(body, now);

  const today = formatDate(now);
  const futureCue = !!todo.date && todo.date >= today && (!!todo.time || todo.date > today);

  let recommended: CaptureKind;
  if (futureCue) recommended = "todo";
  else if (tags.length > 0 || folderName || body.length > 100 || body.includes("\n")) recommended = "note";
  else recommended = "daily";

  return { text, body, tags: [...new Set(tags)], folderName, todo, forced, recommended };
}

/** 解析「标签/文件夹」参数：`#标签` → 标签，`@文件夹` → 文件夹，裸词优先当文件夹名，否则当标签 */
export function parseExtra(extra: string, folders: FolderInfo[]): { tags: string[]; folderName?: string } {
  const tags: string[] = [];
  let folderName: string | undefined;
  for (const token of extra.split(/[\s,，、]+/).filter(Boolean)) {
    if (token.startsWith("#")) {
      const t = token.replace(/^#+/, "");
      if (t) tags.push(t);
    } else if (token.startsWith("@")) {
      const f = token.replace(/^@+/, "");
      if (f) folderName ??= f;
    } else if (matchFolder(token, folders)) {
      folderName ??= token;
    } else {
      tags.push(token);
    }
  }
  return { tags: [...new Set(tags)], folderName };
}

/** 智能推断文件夹：正文里出现了某个已有文件夹的名字（取最长匹配，排除 Daily Note 文件夹） */
export function inferFolder(body: string, folders: FolderInfo[]): FolderInfo | undefined {
  const lower = body.toLowerCase();
  const norm = (s: string) => s.toLowerCase().replace(/[\s_\-·]+/g, "");
  let best: FolderInfo | undefined;
  let bestLen = 0;
  for (const f of folders) {
    const n = norm(f.name);
    if (n.length < 2 || n.replace(/s$/, "") === "dailynote") continue;
    if (lower.includes(n) && n.length > bestLen) {
      best = f;
      bestLen = n.length;
    }
  }
  return best;
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
