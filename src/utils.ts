import { getPrefs } from "./api";

export function formatDate(date: Date): string {
  const yyyy = date.getFullYear().toString();
  const mm = (date.getMonth() + 1).toString().padStart(2, "0");
  const dd = date.getDate().toString().padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

export function getDailyNoteTitle(date?: Date): string {
  const d = date || new Date();
  const { dailyNoteTitleFormat } = getPrefs();
  const format = dailyNoteTitleFormat || "YYYY-MM-DD Daily Note";

  const yyyy = d.getFullYear().toString();
  const mm = (d.getMonth() + 1).toString().padStart(2, "0");
  const dd = d.getDate().toString().padStart(2, "0");

  return format
    .replace("YYYY", yyyy)
    .replace("MM", mm)
    .replace("DD", dd);
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

export function nowTimestamp(): string {
  const d = new Date();
  const hh = d.getHours().toString().padStart(2, "0");
  const mi = d.getMinutes().toString().padStart(2, "0");
  return `${hh}:${mi}`;
}
