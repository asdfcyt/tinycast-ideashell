import { Clipboard, LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { createNote, createTodos, listFolders } from "./api";
import { analyzeCapture, CaptureKind, inferFolder, matchFolder, parseExtra } from "./capture-parse";
import { appendToToday } from "./daily";
import { getDefaultTags, truncate } from "./utils";

interface SmartCaptureArgs {
  text?: string;
  /** auto | todo | daily | note | clipboard，空 = auto */
  type?: string;
  /** 标签/文件夹：#标签 @文件夹，空 = 智能识别 */
  extra?: string;
}

const CLIPBOARD_WORDS = /^(?:剪贴板|剪切板|clip|clipboard|paste)$/i;
const firstLine = (s: string) => s.split(/\r?\n/).find((l) => l.trim())?.trim() ?? "";

const KIND_LABEL: Record<CaptureKind, string> = { todo: "待办", daily: "Daily Note", note: "笔记" };

async function readClipboard(): Promise<string> {
  const clip = ((await Clipboard.readText()) ?? "").trim();
  if (!clip) throw new Error("剪贴板里没有文字");
  return clip;
}

/**
 * 万能输入：根据内容自动分流并执行，返回给 HUD 的结果说明。
 * - 类型：下拉指定 > 文字前缀 > 智能识别
 * - 正文留空 / 选「剪贴板 → 笔记」/ 输入「剪贴板」：使用剪贴板文字
 * - 标签/文件夹：参数 > 正文里的 #标签 @文件夹 > 智能识别（文件夹名出现在正文中）
 */
async function capture(args: SmartCaptureArgs): Promise<string> {
  const rawText = (args.text ?? "").trim();
  const typeArg = (args.type ?? "").trim();
  const explicit: CaptureKind | undefined =
    typeArg === "todo" || typeArg === "daily" || typeArg === "note" ? typeArg : undefined;

  // 1. 决定内容来源
  let fromClipboard = false;
  let source = rawText;
  const analysisOfText = analyzeCapture(rawText);

  if (typeArg === "clipboard") {
    const clip = await readClipboard();
    source = rawText ? `${rawText}\n\n${clip}` : clip;
    fromClipboard = true;
  } else if (!rawText) {
    source = await readClipboard();
    fromClipboard = true;
  } else if (CLIPBOARD_WORDS.test(analysisOfText.body)) {
    const clip = await readClipboard();
    source = analysisOfText.forced
      ? rawText.replace(/(?:剪贴板|剪切板|clip|clipboard|paste)\s*$/i, clip)
      : clip;
    fromClipboard = true;
  }

  const a = analyzeCapture(source);
  if (!a.body) throw new Error("没有可保存的内容");

  // 2. 决定类型
  const kind: CaptureKind = explicit ?? a.forced ?? (fromClipboard ? "note" : a.recommended);
  const how = explicit || a.forced ? "" : fromClipboard ? "剪贴板" : "智能识别";
  const kindText = `${KIND_LABEL[kind]}${how ? `（${how}）` : ""}`;

  // 3. 标签 / 文件夹
  const folders = kind === "note" || args.extra?.trim() ? await listFolders().catch(() => []) : [];
  const extra = parseExtra(args.extra ?? "", folders);
  const tags = [...new Set([...a.tags, ...extra.tags])];
  const folderName = extra.folderName ?? a.folderName;

  if (kind === "todo") {
    const { content, date, time } = a.todo;
    await createTodos([{ content, ...(date ? { date } : {}), ...(time ? { time } : {}) }]);
    const when = [date, time].filter(Boolean).join(" ");
    return `✅ ${kindText}：${truncate(content, 24)}${when ? `（${when}）` : ""}`;
  }

  if (kind === "daily") {
    const entry = [a.body, ...tags.map((t) => `#${t}`)].join(" ");
    await appendToToday(entry);
    return `✅ ${kindText}：${truncate(firstLine(a.body), 24)}`;
  }

  // 笔记
  let folderId: string | undefined;
  let folderNote = "";
  if (folderName) {
    const folder = matchFolder(folderName, folders);
    if (folder) {
      folderId = folder.id;
      folderNote = ` 📁${folder.name}`;
    } else {
      folderNote = `（文件夹「${folderName}」不存在，已放在未归档）`;
    }
  } else {
    const inferred = inferFolder(a.body, folders);
    if (inferred) {
      folderId = inferred.id;
      folderNote = ` 📁${inferred.name}`;
    }
  }

  const title = truncate(firstLine(a.body), 30);
  const allTags = [...new Set([...getDefaultTags(), ...tags])];
  await createNote({
    title,
    body: a.body,
    tags: allTags.length > 0 ? allTags : undefined,
    folder: folderId,
    source: "tinycast",
  });
  return `✅ ${kindText}：${truncate(title, 24)}${tags.length ? ` ${tags.map((t) => `#${t}`).join(" ")}` : ""}${folderNote}`;
}

export default async function Command(props: LaunchProps<{ arguments: SmartCaptureArgs }>) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "正在保存..." });
  try {
    const message = await capture(props.arguments);
    toast.hide();
    await showHUD(message);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "保存失败";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
