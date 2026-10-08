import { execFile } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { NoteAttachment } from "./api";

const MB = 1024 * 1024;

const IMAGE_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
/** 接口不收的图片格式，用系统自带的 sips 转成 JPEG 后上传 */
const CONVERT_EXT = new Set(["heic", "heif", "tif", "tiff", "bmp", "avif"]);
const AUDIO_EXT = new Set(["mp3", "m4a", "wav", "aac"]);
const OFFICE_EXT = new Set(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]);
const TEXT_EXT = new Set(["txt", "md", "csv", "log", "json", "xml", "yaml", "yml"]);

export const LIMITS = { images: 9, audios: 5, documents: 5 } as const;

export type AttachKind = "image" | "convert" | "audio" | "document" | "unsupported";

export function extOf(file: string): string {
  return path.extname(file).slice(1).toLowerCase();
}

export function classify(file: string): AttachKind {
  const ext = extOf(file);
  if (IMAGE_EXT.has(ext)) return "image";
  if (CONVERT_EXT.has(ext)) return "convert";
  if (AUDIO_EXT.has(ext)) return "audio";
  if (OFFICE_EXT.has(ext) || TEXT_EXT.has(ext)) return "document";
  return "unsupported";
}

/** 表单里的实时摘要，如「🖼 2 张图片 · 📄 1 个文档 · ⚠️ 1 个不支持」 */
export function summarize(files: string[]): string {
  const count = { image: 0, audio: 0, document: 0, unsupported: 0 };
  for (const f of files) {
    const k = classify(f);
    if (k === "image" || k === "convert") count.image++;
    else count[k]++;
  }
  return [
    count.image && `🖼 ${count.image} 张图片`,
    count.audio && `🎙 ${count.audio} 个音频`,
    count.document && `📄 ${count.document} 个文档`,
    count.unsupported && `⚠️ ${count.unsupported} 个不支持（将跳过）`,
  ]
    .filter(Boolean)
    .join(" · ");
}

function runSips(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/sips", args, (err) => (err ? reject(err) : resolve()));
  });
}

function tmpFile(ext: string): string {
  let dir = "/tmp";
  try {
    dir = os.tmpdir() || "/tmp";
  } catch {
    // 使用默认值
  }
  return path.join(dir, `ideashell-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`);
}

const b64 = (file: string) => fs.readFileSync(file).toString("base64");

/** 图片：合规直接传；HEIC 等格式或超过 5MB 时用 sips 转 JPEG，必要时逐级缩小 */
async function prepareImage(file: string, kind: AttachKind): Promise<NoteAttachment> {
  const base = path.basename(file);
  if (kind === "image" && fs.statSync(file).size <= 5 * MB) return { data: b64(file), name: base };

  const out = tmpFile("jpg");
  try {
    for (const maxDim of [3000, 2000, 1280]) {
      await runSips(["-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", String(maxDim), file, "--out", out]);
      if (fs.statSync(out).size <= 5 * MB - 4096) break;
    }
    return { data: b64(out), name: `${path.basename(file, path.extname(file))}.jpg` };
  } finally {
    try {
      fs.unlinkSync(out);
    } catch {
      // 临时文件清理失败可忽略
    }
  }
}

export interface PreparedFiles {
  images: NoteAttachment[];
  audios: NoteAttachment[];
  documents: NoteAttachment[];
  skipped: string[];
}

/** 读取并按接口限制整理文件；超出数量上限时抛错（请分批），单个文件不合规则跳过并记录原因 */
export async function prepareFiles(files: string[]): Promise<PreparedFiles> {
  const result: PreparedFiles = { images: [], audios: [], documents: [], skipped: [] };

  for (const file of files) {
    const name = path.basename(file);
    const kind = classify(file);
    try {
      if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
        result.skipped.push(`${name}（不是文件）`);
        continue;
      }
      const size = fs.statSync(file).size;

      if (kind === "unsupported") {
        result.skipped.push(`${name}（不支持的格式）`);
      } else if (kind === "image" || kind === "convert") {
        result.images.push(await prepareImage(file, kind));
      } else if (kind === "audio") {
        if (size > 25 * MB) result.skipped.push(`${name}（音频超过 25MB）`);
        else result.audios.push({ data: b64(file), name });
      } else {
        const limit = OFFICE_EXT.has(extOf(file)) ? 50 * MB : 5 * MB;
        if (size > limit) result.skipped.push(`${name}（超过 ${limit / MB}MB）`);
        else result.documents.push({ data: b64(file), name });
      }
    } catch (e) {
      result.skipped.push(`${name}（${e instanceof Error ? e.message : String(e)}）`);
    }
  }

  const over = [
    result.images.length > LIMITS.images && `图片最多 ${LIMITS.images} 张`,
    result.audios.length > LIMITS.audios && `音频最多 ${LIMITS.audios} 个`,
    result.documents.length > LIMITS.documents && `文档最多 ${LIMITS.documents} 个`,
  ].filter(Boolean);
  if (over.length > 0) throw new Error(`单条笔记${over.join("，")}，请分批保存`);

  return result;
}
