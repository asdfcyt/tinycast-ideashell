import { createFolder, getNotesByFolder, getPrefs, listFolders, FolderInfo, NoteInfo } from "./api";

const DATE_RE = /\d{4}-\d{2}-\d{2}/;

/** 文件夹名归一化："Daily Notes" / "Dailynotes" / "daily-note" 都视为同一个 */
function normalizeFolderName(name: string): string {
  return name
    .toLowerCase()
    .replace(/[\s_\-·]+/g, "")
    .replace(/s$/, "");
}

export function getDailyFolderName(): string {
  return getPrefs().dailyNoteFolder?.trim() || "Daily Notes";
}

/**
 * 每次都从 folder_list 实时查找 Daily Note 文件夹（不再缓存 ID，
 * 避免文件夹被改名/删除或偏好设置变更后拿到过期的 ID）。
 */
export async function findDailyFolder(): Promise<FolderInfo | undefined> {
  const folders = await listFolders();
  const wanted = getDailyFolderName();
  const wantedNorm = normalizeFolderName(wanted);

  return (
    folders.find((f) => f.name.trim().toLowerCase() === wanted.toLowerCase()) ||
    folders.find((f) => normalizeFolderName(f.name) === wantedNorm) ||
    folders.find((f) => normalizeFolderName(f.name) === "dailynote")
  );
}

export async function getOrCreateDailyFolderId(): Promise<string> {
  const found = await findDailyFolder();
  if (found) return found.id;

  const result = await createFolder(getDailyFolderName());
  return result.match(/folder_id[:\s"]*([a-f0-9]+)/i)?.[1] || result.match(/[a-f0-9]{32}/i)?.[0] || "";
}

export function extractDate(title: string): string {
  return title.match(DATE_RE)?.[0] || "";
}

/** Daily Note 文件夹中的全部笔记，按标题里的日期倒序 */
export async function listDailyNotes(): Promise<{ notes: NoteInfo[]; folder?: FolderInfo }> {
  const folder = await findDailyFolder();
  if (!folder) return { notes: [] };

  const notes = await getNotesByFolder(folder.id);
  notes.sort((a, b) => extractDate(b.title).localeCompare(extractDate(a.title)));
  return { notes, folder };
}

/** 在文件夹中找到标题日期等于 date 的 Daily Note */
export async function findDailyNoteByDate(date: string): Promise<NoteInfo | undefined> {
  const { notes } = await listDailyNotes();
  return notes.find((n) => extractDate(n.title) === date);
}

// ── 追加排版 ──

/** 时间戳行："**2026-10-08 11:37:40** xxx" / "2026-10-08 11:37 xxx" / "- **2026-10-08 11:37** xxx" */
const ENTRY_RE = /^\s*(?:[-*+]\s+)?(?:\*\*)?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})(?::\d{2})?(?:\*\*)?[ \t]*(.*)$/;

export function nowMinuteStamp(d = new Date()): string {
  const yyyy = d.getFullYear();
  const mm = (d.getMonth() + 1).toString().padStart(2, "0");
  const dd = d.getDate().toString().padStart(2, "0");
  const hh = d.getHours().toString().padStart(2, "0");
  const mi = d.getMinutes().toString().padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${mi}`;
}

/** 生成一条列表条目：`- **时间** 内容`，多行内容用缩进保持在同一条目内 */
export function formatEntry(text: string, stamp = nowMinuteStamp()): string {
  const [first, ...rest] = text.trim().split(/\r?\n/);
  return [`- **${stamp}** ${first}`, ...rest.map((l) => (l.trim() ? `  ${l}` : ""))].join("\n");
}

/** 把旧格式（挤在一起、带秒、无列表符号）的条目统一整理为列表格式；其余内容原样保留 */
export function normalizeDailyContent(content: string): string {
  return content
    .split(/\r?\n/)
    .map((line) => {
      const m = line.match(ENTRY_RE);
      return m ? `- **${m[1]}** ${m[2]}`.trimEnd() : line;
    })
    .join("\n")
    .trim();
}

export function appendEntry(oldContent: string, text: string): string {
  const entry = formatEntry(text);
  const normalized = normalizeDailyContent(oldContent || "");
  return normalized ? `${normalized}\n${entry}` : entry;
}
