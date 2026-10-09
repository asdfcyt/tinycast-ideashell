import { Clipboard } from "@raycast/api";
import { warmUp } from "./api";
import { analyzeCapture, CaptureKind, inferFolder, matchFolder } from "./capture-parse";
import { saveCapture } from "./capture-core";
import { getFoldersFast, getFoldersFresh } from "./folders-cache";

export interface SmartCaptureArgs {
  text?: string;
  /** 没有写前缀时的默认类型（不传则智能识别）；写了「待办 / 日记」等前缀仍以前缀为准 */
  defaultKind?: CaptureKind;
  /** 额外追加的标签（如项目的关键词 / 标签） */
  extraTags?: string[];
}

const CLIPBOARD_WORDS = /^(?:剪贴板|剪切板|clip|clipboard|paste)$/i;

async function readClipboard(): Promise<string> {
  const clip = ((await Clipboard.readText()) ?? "").trim();
  if (!clip) throw new Error("剪贴板里没有文字");
  return clip;
}

/**
 * 万能输入（搜索栏直接保存）：根据内容自动分流并执行，返回给 HUD 的结果说明。
 * - 类型：文字前缀（待办 / 日记 / 笔记）> 智能识别
 * - 内容写成「剪贴板」：使用剪贴板里的文字
 * - 标签 / 文件夹：正文里的 #标签 @文件夹 > 智能识别（文件夹名出现在正文中）
 */
export async function runCapture(args: SmartCaptureArgs): Promise<string> {
  warmUp(); // 握手与下面的解析 / 读剪贴板并行
  const rawText = (args.text ?? "").trim();

  // 1. 决定内容来源
  let fromClipboard = false;
  let source = rawText;
  const first = analyzeCapture(rawText);
  if (!rawText) {
    source = await readClipboard();
    fromClipboard = true;
  } else if (CLIPBOARD_WORDS.test(first.body)) {
    const clip = await readClipboard();
    source = first.forced ? rawText.replace(/(?:剪贴板|剪切板|clip|clipboard|paste)\s*$/i, clip) : clip;
    fromClipboard = true;
  }

  const a = analyzeCapture(source);
  if (!a.body) throw new Error("没有可保存的内容");

  // 2. 决定类型
  const kind: CaptureKind = a.forced ?? args.defaultKind ?? (fromClipboard ? "note" : a.recommended);
  const how = a.forced || args.defaultKind ? "" : fromClipboard ? "剪贴板" : "智能识别";

  // 3. 文件夹（仅笔记）
  let folderId: string | undefined;
  let folderNote = "";
  if (kind === "note") {
    let folders = await getFoldersFast();
    if (a.folderName) {
      let folder = matchFolder(a.folderName, folders);
      if (!folder) {
        // 缓存里没有：可能是刚新建的文件夹，拉一次最新的再判断
        folders = await getFoldersFresh();
        folder = matchFolder(a.folderName, folders);
      }
      if (folder) {
        folderId = folder.id;
        folderNote = ` 📁${folder.name}`;
      } else {
        folderNote = `（文件夹「${a.folderName}」不存在，已放在未归档）`;
      }
    } else {
      const inferred = inferFolder(a.body, folders);
      if (inferred) {
        folderId = inferred.id;
        folderNote = ` 📁${inferred.name}`;
      }
    }
  }

  return saveCapture({
    kind,
    body: a.body,
    todo: a.todo,
    tags: [...new Set([...a.tags, ...(args.extraTags ?? [])])],
    folderId,
    folderNote,
    how,
  });
}
