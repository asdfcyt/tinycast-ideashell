import { projectTerms, WatchItem } from "./watchlist";
import { formatDate } from "./utils";

/**
 * 待办的「重要 / 紧急」标记直接写在待办文字里（换设备也在）：
 * `!重要`、`!紧急`。紧急还会按日期自动判断（今天、明天或已逾期）。
 */
const IMPORTANT_RE = /\s*[!！]重要/g;
const URGENT_RE = /\s*[!！]紧急/g;

export const isMarkedImportant = (content: string) => /[!！]重要/.test(content);
export const isMarkedUrgent = (content: string) => /[!！]紧急/.test(content);

export function cleanTitle(content: string): string {
  return content.replace(IMPORTANT_RE, "").replace(URGENT_RE, "").trim() || content;
}

export function toggleMark(content: string, mark: "重要" | "紧急"): string {
  const re = mark === "重要" ? IMPORTANT_RE : URGENT_RE;
  const has = mark === "重要" ? isMarkedImportant(content) : isMarkedUrgent(content);
  return has ? content.replace(re, "").trim() : `${content.trim()} !${mark}`;
}

export type Quadrant = "q1" | "q2" | "q3" | "q4";

export const QUADRANT_TITLE: Record<Quadrant, string> = {
  q1: "重要且紧急",
  q2: "重要不紧急",
  q3: "紧急但不重要",
  q4: "不重要不紧急",
};

export function quadrantOf(todo: { content: string; date: string | null }, now = new Date()): Quadrant {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  const limit = formatDate(d);
  const important = isMarkedImportant(todo.content);
  const urgent = isMarkedUrgent(todo.content) || (!!todo.date && todo.date <= limit);
  if (important) return urgent ? "q1" : "q2";
  return urgent ? "q3" : "q4";
}

/** 待办属于哪个项目：文字里含有项目关键词或其标签（取第一个命中的） */
export function projectOf(content: string, projects: WatchItem[], tags: string[] = []): WatchItem | undefined {
  const text = content.toLowerCase();
  const tagSet = new Set(tags.map((t) => t.toLowerCase()));
  return projects.find((p) =>
    projectTerms(p).some((t) => text.includes(t.toLowerCase()) || tagSet.has(t.toLowerCase())),
  );
}
