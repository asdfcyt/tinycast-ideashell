import { showHUD, showToast, Toast, LaunchProps, LocalStorage } from "@raycast/api";
import { createNote, updateNote, searchNotes, getNoteDetail, getPrefs } from "./api";
import { getDailyNoteTitle, nowTimestamp, truncate, formatDate } from "./utils";

interface DailyNoteArgs {
  text: string;
}

const DAILY_NOTE_ID_PREFIX = "daily-note-id-";

function storageKey(date?: Date): string {
  return DAILY_NOTE_ID_PREFIX + formatDate(date || new Date());
}

async function findOrCreateDailyNote(date?: Date): Promise<{ id: string; isNew: boolean; body: string }> {
  const d = date || new Date();
  const key = storageKey(d);
  const title = getDailyNoteTitle(d);
  const { dailyNoteFolder } = getPrefs();

  const cachedId = await LocalStorage.getItem<string>(key);

  if (cachedId) {
    try {
      const detail = await getNoteDetail(cachedId);
      return { id: cachedId, isNew: false, body: detail.body || "" };
    } catch {
      await LocalStorage.removeItem(key);
    }
  }

  const results = await searchNotes(title);
  const match = results.find((n) => n.title === title);

  if (match && match.id) {
    await LocalStorage.setItem(key, match.id);
    try {
      const detail = await getNoteDetail(match.id);
      return { id: match.id, isNew: false, body: detail.body || "" };
    } catch {
      return { id: match.id, isNew: false, body: "" };
    }
  }

  const dateStr = formatDate(d);
  const initialBody = `# ${title}\n\n📅 ${dateStr}\n\n---\n\n`;
  const result = await createNote({
    title,
    body: initialBody,
    tags: ["daily-note"],
    folder: dailyNoteFolder || undefined,
  });

  const idMatch = result.match(/[a-f0-9]{24,}/i);
  const noteId = idMatch ? idMatch[0] : "";

  if (noteId) {
    await LocalStorage.setItem(key, noteId);
  } else {
    const newResults = await searchNotes(title);
    const newMatch = newResults.find((n) => n.title === title);
    if (newMatch?.id) {
      await LocalStorage.setItem(key, newMatch.id);
      return { id: newMatch.id, isNew: true, body: initialBody };
    }
  }

  return { id: noteId, isNew: true, body: initialBody };
}

export default async function Command(props: LaunchProps<{ arguments: DailyNoteArgs }>) {
  const { text } = props.arguments;

  if (!text.trim()) {
    await showHUD("❌ 请输入内容");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: "正在追加到 Daily Note..." });

  try {
    const { id, body } = await findOrCreateDailyNote();
    const timestamp = nowTimestamp();
    const newEntry = `\n- **${timestamp}** ${text.trim()}\n`;
    const updatedBody = body + newEntry;

    if (id) {
      await updateNote({ id, body: updatedBody });
    } else {
      const title = getDailyNoteTitle();
      const { dailyNoteFolder } = getPrefs();
      await createNote({
        title,
        body: updatedBody,
        tags: ["daily-note"],
        folder: dailyNoteFolder || undefined,
      });
    }

    toast.hide();
    await showHUD(`✅ 已追加到今天的 Daily Note: ${truncate(text, 20)}`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "追加失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
