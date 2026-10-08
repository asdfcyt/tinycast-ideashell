import { showHUD, showToast, Toast, LaunchProps, LocalStorage } from "@raycast/api";
import { createNote, updateNote, getNoteDetail } from "./api";
import { appendEntry, findDailyNoteByDate, formatEntry, getOrCreateDailyFolderId } from "./daily";
import { formatDate } from "./utils";

interface DailyNoteArgs {
  text: string;
}

const DAILY_NOTE_PREFIX = "daily-note-";

function todayKey(): string {
  return DAILY_NOTE_PREFIX + formatDate(new Date());
}

/**
 * 找到今天的 Daily Note：
 * 1. 优先在 Daily Note 文件夹里按标题日期查找（权威来源，换设备/清缓存也不会重复创建）
 * 2. 回退到本地缓存的 note_id
 */
async function findTodayNote(): Promise<{ noteId: string; content: string } | null> {
  const key = todayKey();

  let noteId = "";
  try {
    const found = await findDailyNoteByDate(formatDate(new Date()));
    if (found) noteId = found.note_id || found.id;
  } catch {
    // 文件夹查询失败时回退到缓存
  }

  if (!noteId) {
    noteId = (await LocalStorage.getItem<string>(key)) || "";
  }
  if (!noteId) return null;

  try {
    const detail = await getNoteDetail(noteId);
    await LocalStorage.setItem(key, noteId);
    return { noteId, content: detail.content || detail.body || "" };
  } catch {
    await LocalStorage.removeItem(key);
    return null;
  }
}

export default async function Command(props: LaunchProps<{ arguments: DailyNoteArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在追加到 Daily Note..." });

  try {
    const key = todayKey();
    const existing = await findTodayNote();

    if (existing) {
      // 追加到已有笔记（同时把旧格式条目整理为列表）
      await updateNote({
        noteId: existing.noteId,
        body: appendEntry(existing.content, text),
      });
    } else {
      // 创建新的 daily note
      const folderId = await getOrCreateDailyFolderId();

      const result = await createNote({
        title: formatDate(new Date()),
        body: formatEntry(text),
        tags: ["daily-note"],
        folder: folderId || undefined,
        source: "tinycast",
      });

      // 保存 note_id
      try {
        const parsed = JSON.parse(result);
        if (parsed.note_id) {
          await LocalStorage.setItem(key, parsed.note_id);
        }
      } catch {
        const idMatch = result.match(/[a-f0-9]{32}/i);
        if (idMatch) {
          await LocalStorage.setItem(key, idMatch[0]);
        }
      }
    }

    toast.hide();
    await showHUD(`✅ 已追加到 Daily Note: ${text.trim().slice(0, 20)}`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "追加失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
