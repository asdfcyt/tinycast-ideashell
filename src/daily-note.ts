import { showHUD, showToast, Toast, LaunchProps, LocalStorage } from "@raycast/api";
import { createNote, updateNote, getNoteDetail, getPrefs } from "./api";
import { formatDate } from "./utils";

interface DailyNoteArgs {
  text: string;
}

const DAILY_FOLDER_ID = "dailynote-folder-id";
const DAILY_NOTE_PREFIX = "daily-note-";

function todayKey(): string {
  return DAILY_NOTE_PREFIX + formatDate(new Date());
}

function todayTitle(): string {
  return formatDate(new Date());
}

function nowFullTimestamp(): string {
  const d = new Date();
  const yyyy = d.getFullYear();
  const mm = (d.getMonth() + 1).toString().padStart(2, "0");
  const dd = d.getDate().toString().padStart(2, "0");
  const hh = d.getHours().toString().padStart(2, "0");
  const mi = d.getMinutes().toString().padStart(2, "0");
  const ss = d.getSeconds().toString().padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
}

async function getDailynoteFolder(): Promise<string> {
  const cached = await LocalStorage.getItem<string>(DAILY_FOLDER_ID);
  if (cached) return cached;

  // 调用 folder_list 从文本中解析 Dailynote 文件夹 ID
  const { callToolRaw } = await import("./api");
  const resp = await callToolRaw("folder_list", {});
  const text = resp;

  // 解析格式: "- 📁 Dailynote [folder_id: xxx]"
  const match = text.match(/Dailynote\s*\[folder_id:\s*([a-f0-9]+)\]/i);
  if (match) {
    await LocalStorage.setItem(DAILY_FOLDER_ID, match[1]);
    return match[1];
  }

  // 如果找不到 Dailynote 文件夹则创建一个
  const { createFolder } = await import("./api");
  const createResult = await createFolder("Dailynote");
  const folderIdMatch = createResult.match(/folder_id[:\s"]*([a-f0-9]+)/i);
  if (folderIdMatch) {
    await LocalStorage.setItem(DAILY_FOLDER_ID, folderIdMatch[1]);
    return folderIdMatch[1];
  }

  return "";
}

async function findTodayNote(): Promise<{ noteId: string; content: string } | null> {
  const key = todayKey();
  const cachedId = await LocalStorage.getItem<string>(key);

  if (cachedId) {
    try {
      const detail = await getNoteDetail(cachedId);
      // note_detail 返回纯文本，content 在 Memos 下方
      // 但我们更新时用的是完整 content 字段
      // 先尝试读取已有内容
      const text = typeof detail === "string" ? detail : (detail.content || detail.body || "");
      return { noteId: cachedId, content: text };
    } catch {
      await LocalStorage.removeItem(key);
    }
  }

  return null;
}

export default async function Command(props: LaunchProps<{ arguments: DailyNoteArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在追加到 Daily Note..." });

  try {
    const timestamp = nowFullTimestamp();
    const newLine = `${timestamp} ${text.trim()}`;
    const title = todayTitle();
    const key = todayKey();

    // 尝试找到今天已有的笔记
    const existing = await findTodayNote();

    if (existing && existing.noteId) {
      // 追加到已有笔记
      const oldContent = existing.content || "";
      const updatedContent = oldContent ? `${oldContent}\n${newLine}` : newLine;

      await updateNote({
        noteId: existing.noteId,
        body: updatedContent,
      });
    } else {
      // 创建新的 daily note
      const folderId = await getDailynoteFolder();

      const result = await createNote({
        title,
        body: newLine,
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
        const idMatch = result.match(/[a-f0-9]{24,}/i);
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
