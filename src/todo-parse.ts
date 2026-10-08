import { formatDate } from "./utils";

export interface ParsedTodo {
  content: string;
  date?: string; // YYYY-MM-DD
  time?: string; // HH:MM
}

const WEEKDAY_INDEX: Record<string, number> = { 一: 0, 二: 1, 三: 2, 四: 3, 五: 4, 六: 5, 日: 6, 天: 6 }; // 周一 = 0

function addDays(base: Date, days: number): Date {
  const d = new Date(base.getFullYear(), base.getMonth(), base.getDate());
  d.setDate(d.getDate() + days);
  return d;
}

function pad(n: number): string {
  return n.toString().padStart(2, "0");
}

/** 依次尝试识别日期，返回 [日期, 命中的原文]；识别不到返回 null */
function matchDate(text: string, today: Date): [string, string] | null {
  let m: RegExpMatchArray | null;

  // 2026-10-09 / 2026/10/9
  m = text.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (m) return [`${m[1]}-${pad(+m[2])}-${pad(+m[3])}`, m[0]];

  // 10月9日 / 10月9号：已过则按明年
  m = text.match(/(\d{1,2})月(\d{1,2})[日号]?/);
  if (m) {
    let year = today.getFullYear();
    const candidate = new Date(year, +m[1] - 1, +m[2]);
    if (candidate < addDays(today, 0)) year += 1;
    return [`${year}-${pad(+m[1])}-${pad(+m[2])}`, m[0]];
  }

  // 相对日期
  m = text.match(/大后天|后天|明天|明日|今天|今日/);
  if (m) {
    const offset: Record<string, number> = { 今天: 0, 今日: 0, 明天: 1, 明日: 1, 后天: 2, 大后天: 3 };
    return [formatDate(addDays(today, offset[m[0]])), m[0]];
  }

  // 周X / 下周X / 下下周X
  m = text.match(/(下下|下)?(?:周|星期|礼拜)([一二三四五六日天])/);
  if (m) {
    const weeks = m[1] === "下下" ? 2 : m[1] === "下" ? 1 : 0;
    const todayIdx = (today.getDay() + 6) % 7; // 周一 = 0
    const monday = addDays(today, -todayIdx);
    let target = addDays(monday, WEEKDAY_INDEX[m[2]] + weeks * 7);
    if (weeks === 0 && target < addDays(today, 0)) target = addDays(target, 7); // 本周已过 → 下一次
    return [formatDate(target), m[0]];
  }

  return null;
}

/** 识别时间：15:30 / 下午3点 / 3点半 / 晚上8点15分，返回 [HH:MM, 命中的原文] */
function matchTime(text: string): [string, string] | null {
  const period = "(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)?\\s*";
  let m = text.match(new RegExp(`${period}(\\d{1,2})[:：](\\d{2})`));
  let hour: number;
  let minute: number;
  let per: string | undefined;

  if (m) {
    per = m[1];
    hour = +m[2];
    minute = +m[3];
  } else {
    m = text.match(new RegExp(`${period}(\\d{1,2})\\s*[点時时](?:\\s*(半)|\\s*(\\d{1,2})\\s*分?)?`));
    if (!m) return null;
    per = m[1];
    hour = +m[2];
    minute = m[3] ? 30 : m[4] ? +m[4] : 0;
  }

  if ((per === "下午" || per === "晚上" || per === "傍晚") && hour < 12) hour += 12;
  if (per === "中午" && hour < 11) hour += 12;
  if (hour > 23 || minute > 59) return null;

  return [`${pad(hour)}:${pad(minute)}`, m[0]];
}

/**
 * 解析「明天 15:00 开会」「下周五下午3点交报告」「10月9日 买票」这类输入。
 * 识别到的日期/时间会从内容中移除；只有时间没有日期时默认为今天。
 */
export function parseTodoInput(input: string, now = new Date()): ParsedTodo {
  let text = input.trim();
  let date: string | undefined;
  let time: string | undefined;

  const d = matchDate(text, now);
  if (d) {
    date = d[0];
    text = text.replace(d[1], " ");
  }

  const t = matchTime(text);
  if (t) {
    time = t[0];
    text = text.replace(t[1], " ");
  }

  if (time && !date) date = formatDate(now);

  const content = text
    .replace(/\s+/g, " ")
    .replace(/^[\s,，、:：;；\-—]+|[\s,，、:：;；\-—]+$/g, "")
    .replace(/^(?:在|于|到)\s*/, "")
    .trim();

  return { content: content || input.trim(), date, time };
}

/** 把「明天」「15:30」这样的表单输入解析成日期/时间；解析不出来时 ok=false */
export function parseDateTimeFields(
  dateText: string,
  timeText: string,
  now = new Date(),
): { ok: boolean; date?: string; time?: string } {
  const dt = dateText.trim();
  const tt = timeText.trim();
  if (!dt && !tt) return { ok: true };

  const parsed = parseTodoInput(`${dt} ${tt}`.trim(), now);
  if (dt && !parsed.date) return { ok: false };
  if (tt && !parsed.time) return { ok: false };
  // 只填了时间时，parseTodoInput 会默认日期为今天
  return { ok: true, date: parsed.date, time: tt ? parsed.time : undefined };
}
