import { LocalStorage } from "@raycast/api";
import {
  createFolder,
  createNote,
  getNoteDetail,
  getNotesByFolder,
  getPrefs,
  listFolders,
  updateNote,
  FolderInfo,
  NoteInfo,
} from "./api";
import { formatDate } from "./utils";

const DATE_RE = /\d{4}-\d{2}-\d{2}/;
const DAILY_NOTE_PREFIX = "daily-note-";

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
  return (
    result.match(/folder_id[:\s"]*([a-f0-9]+)/i)?.[1] ||
    result.match(/[a-f0-9]{32}/i)?.[0] ||
    ""
  );
}

export function extractDate(title: string): string {
  return title.match(DATE_RE)?.[0] || "";
}

/** Daily Note 文件夹中的全部笔记，按标题里的日期倒序 */
export async function listDailyNotes(): Promise<{
  notes: NoteInfo[];
  folder?: FolderInfo;
}> {
  const folder = await findDailyFolder();
  if (!folder) return { notes: [] };

  const notes = await getNotesByFolder(folder.id);
  notes.sort((a, b) =>
    extractDate(b.title).localeCompare(extractDate(a.title)),
  );
  return { notes, folder };
}

/** 在文件夹中找到标题日期等于 date 的 Daily Note */
export async function findDailyNoteByDate(
  date: string,
): Promise<NoteInfo | undefined> {
  const { notes } = await listDailyNotes();
  return notes.find((n) => extractDate(n.title) === date);
}

// ── 追加排版 ──

/** 时间戳行："**2026-10-08 11:37:40** xxx" / "2026-10-08 11:37 xxx" / "- **2026-10-08 11:37** xxx" */
const ENTRY_RE =
  /^\s*(?:[-*+]\s+)?(?:\*\*)?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})(?::\d{2})?(?:\*\*)?[ \t]*(.*)$/;

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
  return [
    `- **${stamp}** ${first}`,
    ...rest.map((l) => (l.trim() ? `  ${l}` : "")),
  ].join("\n");
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

// ── 追加到今天的 Daily Note ──

function todayKey(): string {
  return DAILY_NOTE_PREFIX + formatDate(new Date());
}

/**
 * 找到今天的 Daily Note：
 * 1. 优先在 Daily Note 文件夹里按标题日期查找（权威来源，换设备/清缓存也不会重复创建）
 * 2. 回退到本地缓存的 note_id
 */
async function findTodayNote(): Promise<{
  noteId: string;
  content: string;
} | null> {
  const key = todayKey();

  // 快路径：本机今天已经写过，直接用缓存的 note_id（只需 1 次读取），省掉两次文件夹查询
  const cached = (await LocalStorage.getItem<string>(key)) || "";
  if (cached) {
    try {
      const detail = await getNoteDetail(cached);
      return { noteId: cached, content: detail.content || detail.body || "" };
    } catch {
      await LocalStorage.removeItem(key);
    }
  }

  // 慢路径：按文件夹里的标题日期查找（换设备 / 清缓存也不会重复创建）
  let noteId = "";
  try {
    const found = await findDailyNoteByDate(formatDate(new Date()));
    if (found) noteId = found.note_id || found.id;
  } catch {
    // 文件夹查询失败
  }
  if (!noteId) return null;

  try {
    const detail = await getNoteDetail(noteId);
    await LocalStorage.setItem(key, noteId);
    return { noteId, content: detail.content || detail.body || "" };
  } catch {
    return null;
  }
}

/** 追加一条到今天的 Daily Note，不存在则创建；同时把当天旧格式条目整理为列表 */
export async function appendToToday(text: string): Promise<void> {
  const existing = await findTodayNote();

  if (existing) {
    await updateNote({
      noteId: existing.noteId,
      body: appendEntry(existing.content, text),
    });
    return;
  }

  const folderId = await getOrCreateDailyFolderId();
  const result = await createNote({
    title: formatDate(new Date()),
    body: formatEntry(text),
    tags: ["daily-note"],
    folder: folderId || undefined,
    source: "tinycast",
    inlineTags: false,
  });

  const idMatch = result.match(/[a-f0-9]{32}/i);
  if (idMatch) await LocalStorage.setItem(todayKey(), idMatch[0]);
}

/** 去掉开头已有的、带指定标记的引用块（连续以 ">" 开头的行），以及它后面的空行 */
function stripLeadingQuote(content: string, marker: string): string {
  const lines = content.split(/\r?\n/);
  if (!(lines[0]?.trim().startsWith(">") && lines[0].includes(marker)))
    return content;
  let i = 0;
  while (i < lines.length && lines[i].trim().startsWith(">")) i++;
  while (i < lines.length && !lines[i].trim()) i++;
  return lines.slice(i).join("\n");
}

/**
 * 把一段内容块插到今天 Daily Note 的最前面（不存在则创建）。
 * 开头已有带同一标记的引用块就替换掉，所以重复生成不会堆叠。
 */
export async function prependBlockToToday(
  block: string,
  marker: string,
): Promise<void> {
  const existing = await findTodayNote();
  const text = block.trim();

  if (existing) {
    const rest = normalizeDailyContent(
      stripLeadingQuote(existing.content || "", marker),
    ).trim();
    await updateNote({
      noteId: existing.noteId,
      body: rest ? `${text}\n\n${rest}` : text,
    });
    return;
  }

  const folderId = await getOrCreateDailyFolderId();
  const result = await createNote({
    title: formatDate(new Date()),
    body: text,
    tags: ["daily-note"],
    folder: folderId || undefined,
    source: "tinycast",
    inlineTags: false,
  });

  const idMatch = result.match(/[a-f0-9]{32}/i);
  if (idMatch) await LocalStorage.setItem(todayKey(), idMatch[0]);
}
