import { NoteInfo } from "./api";

/** 取出 memo 正文：丢掉头部元信息、memo 标题行、重复的 `summary:` 行和分隔线 */
export function memoText(text: string): string {
  const i = text.indexOf("## Memos");
  const memos = i >= 0 ? text.slice(i + "## Memos".length) : text;
  return memos
    .split("\n")
    .filter((l) => !/^summary:/i.test(l.trim()) && l.trim() !== "---")
    .join("\n")
    .replace(/\*\*Memo \d+:[^*]*\*\*/g, " ");
}

/** 笔记标签：接口 tags 字段 + 正文里的行内 `#标签` */
export function extractTags(note: NoteInfo, body: string): string[] {
  const set = new Set<string>(note.tags ?? []);
  for (const m of body.matchAll(/#([\p{L}\p{N}_-]+)/gu)) {
    if (!/^\d+$/.test(m[1])) set.add(m[1]);
  }
  return [...set];
}

/** 字数：汉字按字、英文数字按词，忽略 #标签 */
export function wordCount(body: string): number {
  const clean = body.replace(/#[\p{L}\p{N}_-]+/gu, " ");
  const cjk = clean.match(/[\u4e00-\u9fff]/g)?.length ?? 0;
  const latin = clean.match(/[A-Za-z0-9]+/g)?.length ?? 0;
  return cjk + latin;
}
