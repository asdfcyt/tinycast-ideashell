import { formatDate } from "./utils";

export interface TimeRange {
  label: string;
  start: Date; // 含
  end: Date; // 不含
  clamped?: boolean; // 超过最大跨度被截断
}

const WEEKDAY_NAMES = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
const WEEKDAY_INDEX: Record<string, number> = { 一: 0, 二: 1, 三: 2, 四: 3, 五: 4, 六: 5, 日: 6, 天: 6 }; // 周一 = 0
const MAX_DAYS = 62;

function day(d: Date, offset = 0): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + offset);
}

export function weekdayName(d: Date): string {
  return WEEKDAY_NAMES[d.getDay()];
}

function cnToNumber(s: string): number {
  if (/^\d+$/.test(s)) return Number(s);
  const digit: Record<string, number> = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (s === "十") return 10;
  if (s.startsWith("十")) return 10 + (digit[s[1]] ?? 0);
  if (s.includes("十")) {
    const [a, b] = s.split("十");
    return (digit[a] ?? 0) * 10 + (digit[b] ?? 0);
  }
  return digit[s] ?? 0;
}

function dayLabel(d: Date): string {
  return `${formatDate(d)} ${weekdayName(d)}`;
}

function single(d: Date): TimeRange {
  return { label: dayLabel(d), start: day(d), end: day(d, 1) };
}

function span(label: string, start: Date, endExclusive: Date): TimeRange {
  return { label, start, end: endExclusive };
}

/** 找出文本里出现的所有明确日期（YYYY-MM-DD / M月D日），M月D日 若晚于今天则取去年 */
function findDates(text: string, today: Date): Date[] {
  const re = /(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})|(\d{1,2})月(\d{1,2})[日号]?/g;
  const result: Date[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m[1]) {
      result.push(new Date(+m[1], +m[2] - 1, +m[3]));
    } else {
      let d = new Date(today.getFullYear(), +m[4] - 1, +m[5]);
      if (d > today) d = new Date(today.getFullYear() - 1, +m[4] - 1, +m[5]);
      result.push(d);
    }
  }
  return result.filter((d) => !Number.isNaN(d.getTime()));
}

/**
 * 解析时间范围：留空=最近 7 天；今天/昨天/前天；本周/上周；本月/上月；
 * 最近N天/周/月；周三/上周三；10月3日；2026-10-01；10月1日到10月7日
 */
export function parseRange(input: string, now = new Date()): TimeRange | null {
  const today = day(now);
  const t = input.replace(/\s+/g, "");
  let r: TimeRange | null = null;

  if (!t) {
    r = span("最近 7 天", day(today, -6), day(today, 1));
  } else if (/^(今天|今日)$/.test(t)) {
    r = single(today);
  } else if (/^(昨天|昨日)$/.test(t)) {
    r = single(day(today, -1));
  } else if (/^前天$/.test(t)) {
    r = single(day(today, -2));
  } else if (/^(本周|这周|这一周|本星期|这星期)$/.test(t)) {
    const monday = day(today, -((today.getDay() + 6) % 7));
    r = span("本周", monday, day(monday, 7));
  } else if (/^(上周|上一周|上星期|上个星期|上礼拜)$/.test(t)) {
    const monday = day(today, -((today.getDay() + 6) % 7) - 7);
    r = span("上周", monday, day(monday, 7));
  } else if (/^(本月|这个月|当月)$/.test(t)) {
    r = span("本月", new Date(today.getFullYear(), today.getMonth(), 1), new Date(today.getFullYear(), today.getMonth() + 1, 1));
  } else if (/^(上月|上个月)$/.test(t)) {
    r = span("上月", new Date(today.getFullYear(), today.getMonth() - 1, 1), new Date(today.getFullYear(), today.getMonth(), 1));
  } else {
    const recent = t.match(/^(?:最近|近|过去)([\d一二两三四五六七八九十]+)(天|日|周|个月|月)$/);
    const weekday = t.match(/^(上|这|本)?(?:周|星期|礼拜)([一二三四五六日天])$/);
    if (recent) {
      const n = cnToNumber(recent[1]);
      if (n > 0) {
        const days = recent[2] === "天" || recent[2] === "日" ? n : recent[2] === "周" ? n * 7 : n * 30;
        r = span(`最近 ${days} 天`, day(today, -(days - 1)), day(today, 1));
      }
    } else if (weekday) {
      const monday = day(today, -((today.getDay() + 6) % 7) - (weekday[1] === "上" ? 7 : 0));
      r = single(day(monday, WEEKDAY_INDEX[weekday[2]]));
    } else {
      const dates = findDates(t, today);
      if (dates.length === 1) {
        r = single(dates[0]);
      } else if (dates.length >= 2) {
        const [a, b] = [dates[0], dates[1]].sort((x, y) => x.getTime() - y.getTime());
        r = span(`${formatDate(a)} ~ ${formatDate(b)}`, a, day(b, 1));
      }
    }
  }

  if (!r) return null;

  // 超长范围截断，避免一次拉取过多
  const days = Math.round((r.end.getTime() - r.start.getTime()) / 86400000);
  if (days > MAX_DAYS) {
    return { ...r, start: day(r.end, -MAX_DAYS), clamped: true };
  }
  return r;
}

/** 范围内最后一天（含），用于 todo_list 的 date_to */
export function lastDayOf(range: TimeRange): Date {
  return day(range.end, -1);
}
