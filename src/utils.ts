import { getPrefs } from "./api";

export function formatDate(date: Date): string {
  const yyyy = date.getFullYear().toString();
  const mm = (date.getMonth() + 1).toString().padStart(2, "0");
  const dd = date.getDate().toString().padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

/** 本地 "YYYY-MM-DD HH:mm"（进展 / 里程碑 / 复盘的记录时间，精确到分钟） */
export function formatMinute(date: Date): string {
  return `${formatDate(date)} ${date.getHours().toString().padStart(2, "0")}:${date.getMinutes().toString().padStart(2, "0")}`;
}

export function getDailyNoteTitle(date?: Date): string {
  const d = date || new Date();
  const { dailyNoteTitleFormat } = getPrefs();
  const format = dailyNoteTitleFormat || "YYYY-MM-DD Daily Note";

  const yyyy = d.getFullYear().toString();
  const mm = (d.getMonth() + 1).toString().padStart(2, "0");
  const dd = d.getDate().toString().padStart(2, "0");

  return format.replace("YYYY", yyyy).replace("MM", mm).replace("DD", dd);
}

export function getDefaultTags(): string[] {
  const { defaultTags } = getPrefs();
  if (!defaultTags) return [];
  return defaultTags
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
}

export function truncate(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen - 1) + "…";
}

/** ISO 时间 → 本地 "YYYY-MM-DD HH:mm"（无法解析则原样返回） */
export function formatDateTime(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return `${formatDate(d)} ${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
}

/** 列表右侧的短时间：今天 → "11:37"，其余 → "10-07"，跨年 → "2025-12-31" */
export function shortTime(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const now = new Date();
  if (formatDate(d) === formatDate(now)) {
    return `${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
  }
  const full = formatDate(d);
  return d.getFullYear() === now.getFullYear() ? full.slice(5) : full;
}

/** 按距今天数分组名：今天 / 昨天 / 最近 7 天 / 更早 */
export function dayGroup(iso?: string): string {
  if (!iso) return "更早";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "更早";
  const startOfDay = (x: Date) =>
    new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((startOfDay(new Date()) - startOfDay(d)) / 86400000);
  if (diff <= 0) return "今天";
  if (diff === 1) return "昨天";
  if (diff <= 7) return "最近 7 天";
  return "更早";
}

/**
 * 笔记预览的统一排版：标题 → 摘要（引用块）→ 正文。
 * 正文与摘要重复（短笔记常见）时不重复显示摘要。
 */
export function buildNoteMarkdown(opts: {
  title: string;
  summary?: string;
  body?: string; // undefined 表示正文尚未加载
  loading?: boolean;
}): string {
  const { title, summary, body, loading } = opts;
  const parts = [`# ${title || "无标题"}`];

  const body_ = body?.trim();
  const sum = summary?.trim();
  const duplicated =
    !!sum && !!body_ && (body_ === sum || body_.startsWith(sum));
  if (sum && !duplicated) {
    parts.push(`> **摘要**　${sum.replace(/\n+/g, " ")}`);
  }

  if (body === undefined) {
    parts.push(loading ? "*加载全文中…*" : "*选中后加载全文*");
  } else if (body_) {
    parts.push(body_);
  } else if (!sum) {
    parts.push("*（空白笔记）*");
  }

  return parts.join("\n\n");
}

export function nowTimestamp(): string {
  const d = new Date();
  const hh = d.getHours().toString().padStart(2, "0");
  const mi = d.getMinutes().toString().padStart(2, "0");
  return `${hh}:${mi}`;
}
