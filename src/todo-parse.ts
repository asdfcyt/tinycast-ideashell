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

/** 阿拉伯数字或中文数字（一 ~ 九十九） */
const N = "(?:\\d{1,2}|[零〇一二三四五六七八九十两]{1,3})";
const CN_DIGIT: Record<string, number> = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };

/** 「12」「九」「十二」「二十三」→ 数字；认不出返回 null */
function num(s: string): number | null {
  if (/^\d+$/.test(s)) return +s;
  const ten = s.indexOf("十");
  if (ten < 0) return s.length === 1 && s in CN_DIGIT ? CN_DIGIT[s] : null;
  const head = s.slice(0, ten);
  const tail = s.slice(ten + 1);
  let tens = 1;
  if (head) {
    if (head.length !== 1 || !(head in CN_DIGIT)) return null;
    tens = CN_DIGIT[head];
  }
  let ones = 0;
  if (tail) {
    if (tail.length !== 1 || !(tail in CN_DIGIT)) return null;
    ones = CN_DIGIT[tail];
  }
  return tens * 10 + ones;
}

/** 今年的 month 月 day 日；已经过去就取明年的（最近有效）。日期不存在返回 null */
function nearestDate(today: Date, month: number, day: number): string | null {
  const build = (year: number) => {
    const d = new Date(year, month - 1, day);
    return d.getMonth() === month - 1 && d.getDate() === day ? d : null;
  };
  const t = addDays(today, 0);
  const first = build(today.getFullYear());
  if (!first) return null;
  const date = first < t ? build(today.getFullYear() + 1) : first;
  return date ? formatDate(date) : null;
}

/** 只说了时段时的默认时间 */
const PERIOD_DEFAULT: Record<string, string> = {
  凌晨: "03:00",
  早上: "07:00",
  早晨: "07:00",
  上午: "09:00",
  中午: "12:00",
  下午: "14:30",
  傍晚: "17:00",
  晚上: "20:00",
};

/** 依次尝试识别日期，返回 [日期, 命中的原文]；识别不到返回 null */
function matchDate(text: string, today: Date): [string, string] | null {
  let m: RegExpMatchArray | null;

  // 2026-10-09 / 2026/10/9
  m = text.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (m) return [`${m[1]}-${pad(+m[2])}-${pad(+m[3])}`, m[0]];

  // 10月9日 / 十月九日（中文数字的日必须带「日 / 号」）、10月9（没写「日」，只认阿拉伯数字）：已过则按明年
  for (const re of [new RegExp(`(${N})月\\s*(${N})[日号]`), /(\d{1,2})月\s*(\d{1,2})(?![\d点時时:：])/]) {
    m = text.match(re);
    if (m) {
      const month = num(m[1]);
      const day = num(m[2]);
      const date = month !== null && day !== null ? nearestDate(today, month, day) : null;
      if (date) return [date, m[0]];
    }
  }

  // 3/6、03/06、3-6、03-06
  m = text.match(/(?<![\d/\-.:：])(\d{1,2})[/-](\d{1,2})(?![\d/\-.:：])/);
  if (m) {
    const date = nearestDate(today, +m[1], +m[2]);
    if (date) return [date, m[0]];
  }

  // 3月 / 三月 / 3月份：最近一个 3 月的第一天
  m = text.match(new RegExp(`(${N})月份?`));
  if (m) {
    const month = num(m[1]);
    const date = month !== null ? nearestDate(today, month, 1) : null;
    if (date) return [date, m[0]];
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
    m = text.match(
      new RegExp(`${period}(${N})\\s*[点時时](?:\\s*(半)|\\s*(\\d{1,2})\\s*分?|\\s*([零〇一二三四五六七八九十]{1,3})分)?`),
    );
    if (!m) {
      // 只说了时段（「下午」「晚上」…）：用该时段的默认时间
      const only = text.match(/(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)(?![茶饭餐])/);
      return only ? [PERIOD_DEFAULT[only[1]], only[0]] : null;
    }
    per = m[1];
    const h = num(m[2]);
    if (h === null) return null;
    hour = h;
    if (m[3]) minute = 30;
    else if (m[4]) minute = +m[4];
    else if (m[5]) {
      const mm = num(m[5]);
      if (mm === null) return null;
      minute = mm;
    } else minute = 0;
    // 「一点东西」「买一点」不是 1 点：中文的「一点」没有时段、也没有半 / 分时不当作时间
    if (!/^\d/.test(m[2]) && !per && hour === 1 && !m[3] && !m[4] && !m[5]) return null;
  }

  if ((per === "下午" || per === "晚上" || per === "傍晚") && hour < 12) hour += 12;
  if (per === "中午" && hour < 11) hour += 12;
  if (hour > 23 || minute > 59) return null;

  return [`${pad(hour)}:${pad(minute)}`, m[0]];
}

/**
 * 解析「明天 15:00 开会」「下周五下午3点交报告」「10月9日 买票」这类输入。
 * 识别到的日期/时间会从内容中移除；只有时间没有日期时取「最近有效」的那一刻（今天这个点没到就是今天，已过就是明天）。
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

  // 只有时间没有日期：取最近有效的那一刻——今天这个点还没到就是今天，已过就是明天
  if (time && !date) {
    const [h, mi] = time.split(":").map(Number);
    const nowMinutes = now.getHours() * 60 + now.getMinutes();
    date = formatDate(h * 60 + mi > nowMinutes ? now : addDays(now, 1));
  }

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
