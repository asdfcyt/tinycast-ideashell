import { LocalStorage } from "@raycast/api";
import { callDida, timezoneName } from "./dida";
import { collectObjects, isoLocal, parseAny, saveSample } from "./dida-tasks";

/**
 * 滴答清单的习惯：菜单栏里一点打卡；在项目里「记一条」时，自动给同名习惯打卡。
 * 习惯接口的返回格式没有公开样例，所以这里全部按「找到有 id + name 的对象」宽松解析，
 * 原始返回会存到本地缓存（dida-sample-habits / dida-sample-habit_checkins），方便对照调整。
 */

export interface Habit {
  id: string;
  name: string;
  /** 每天的目标值（打卡一次写入这个值）；没有则为 1 */
  goal: number;
  unit: string;
  /** 重复规则（RRULE），用来判断今天是否需要打卡 */
  repeat: string;
}

export interface PendingHabit extends Habit {
  /** 今天已有的打卡记录 id（有的话更新它而不是新建） */
  checkinId?: string;
}

const HABITS_KEY = "habits-v1";
const DONE_KEY = "habits-done-v1";
const HABITS_TTL = 12 * 3600 * 1000;

export const stampOf = (d: Date) =>
  d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();

const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/** 今天是否需要打卡：只识别「每周几」（BYDAY=MO,WE）；其他规则一律当作每天 */
export function isDueToday(repeat: string, now = new Date()): boolean {
  const m = repeat.match(/BYDAY=([A-Z,]+)/);
  if (!m) return true;
  return m[1].split(",").includes(WEEKDAYS[now.getDay()]);
}

async function loadHabits(force = false): Promise<Habit[]> {
  try {
    const raw = await LocalStorage.getItem<string>(HABITS_KEY);
    const cache = raw
      ? (JSON.parse(raw) as { at: number; list: Habit[] })
      : null;
    // 空列表只缓存很短时间，避免解析失败 / 刚创建习惯时长时间看不到
    const ttl = cache && cache.list.length === 0 ? 5 * 60 * 1000 : HABITS_TTL;
    if (cache && !force && Date.now() - cache.at < ttl) return cache.list;
  } catch {
    // 缓存坏了就重新拉
  }
  const text = await callDida("list_habits", {});
  await saveSample("habits", text);
  const found: Record<string, unknown>[] = [];
  collectObjects(
    parseAny(text),
    (o) => typeof o.id === "string" && typeof o.name === "string",
    found,
  );
  const list: Habit[] = [];
  for (const o of found) {
    // 已归档 / 已停用的不显示（正常习惯的 status 为 0；archivedTime 对正常习惯也是 2001-01-01 的占位值，不能用）
    if (typeof o.status === "number" && o.status !== 0) continue;
    const goal = typeof o.goal === "number" && o.goal > 0 ? o.goal : 1;
    list.push({
      id: o.id as string,
      name: (o.name as string).trim(),
      goal,
      unit: typeof o.unit === "string" ? o.unit : "",
      repeat: typeof o.repeatRule === "string" ? o.repeatRule : "",
    });
  }
  await LocalStorage.setItem(
    HABITS_KEY,
    JSON.stringify({ at: Date.now(), list }),
  );
  return list;
}

/** 本机记住今天已经打过卡的习惯（接口返回格式解析不出来时的兜底） */
async function loadDone(stamp: number): Promise<Set<string>> {
  try {
    const raw = await LocalStorage.getItem<string>(DONE_KEY);
    const v = raw
      ? (JSON.parse(raw) as { stamp: number; ids: string[] })
      : null;
    return new Set(v && v.stamp === stamp ? v.ids : []);
  } catch {
    return new Set();
  }
}

async function markDone(stamp: number, id: string): Promise<void> {
  const ids = await loadDone(stamp);
  ids.add(id);
  await LocalStorage.setItem(
    DONE_KEY,
    JSON.stringify({ stamp, ids: [...ids] }),
  );
}

interface Checkin {
  id?: string;
  done: boolean;
}

/** 在返回内容里找出今天的打卡记录：对象带 stamp，所属习惯来自 habitId 字段或外层的键 */
function parseCheckins(
  text: string,
  habitIds: Set<string>,
  stamp: number,
): Map<string, Checkin> {
  const out = new Map<string, Checkin>();
  const walk = (v: unknown, cur: string) => {
    if (Array.isArray(v)) {
      for (const x of v) walk(x, cur);
      return;
    }
    if (!v || typeof v !== "object") return;
    const o = v as Record<string, unknown>;
    const hid = typeof o.habitId === "string" ? o.habitId : cur;
    if (
      typeof o.stamp === "number" &&
      o.stamp === stamp &&
      hid &&
      habitIds.has(hid)
    ) {
      const value = typeof o.value === "number" ? o.value : 0;
      const goal = typeof o.goal === "number" ? o.goal : 1;
      const done =
        o.status === 2 ||
        (o.status === undefined && value > 0 && value >= goal);
      const prev = out.get(hid);
      out.set(hid, {
        id: typeof o.id === "string" ? o.id : prev?.id,
        done: done || !!prev?.done,
      });
    }
    for (const [k, child] of Object.entries(o))
      walk(child, habitIds.has(k) ? k : hid);
  };
  walk(parseAny(text), "");
  return out;
}

/** 今天需要打卡、但还没打卡的习惯 */
export async function fetchPendingHabits(
  now = new Date(),
): Promise<PendingHabit[]> {
  const habits = (await loadHabits()).filter((h) => isDueToday(h.repeat, now));
  if (habits.length === 0) return [];
  const stamp = stampOf(now);
  const ids = new Set(habits.map((h) => h.id));
  let checkins = new Map<string, Checkin>();
  try {
    const text = await callDida("get_habit_checkins", {
      habit_ids: [...ids],
      from_stamp: stamp,
      to_stamp: stamp,
      client_timezone: timezoneName(),
    });
    await saveSample("habit_checkins", text);
    checkins = parseCheckins(text, ids, stamp);
  } catch {
    // 读不到打卡记录就只依赖本机记录
  }
  const localDone = await loadDone(stamp);
  return habits
    .filter((h) => !checkins.get(h.id)?.done && !localDone.has(h.id))
    .map((h) => ({ ...h, checkinId: checkins.get(h.id)?.id }));
}

/** 给习惯打卡（写入目标值，状态为已完成） */
export async function checkinHabit(
  h: Habit & { checkinId?: string },
  now = new Date(),
): Promise<void> {
  const stamp = stampOf(now);
  const t = isoLocal(now);
  await callDida("upsert_habit_checkins", {
    habit_id: h.id,
    checkin_data: {
      ...(h.checkinId ? { id: h.checkinId } : {}),
      stamp,
      time: t,
      opTime: t,
      value: h.goal,
      goal: h.goal,
      status: 2,
    },
    client_timezone: timezoneName(),
  });
  await markDone(stamp, h.id);
}

/**
 * 项目「记一条」后：如果滴答里有和项目同名的习惯（例如项目「篆刻」、习惯「篆刻」），自动打卡。
 * 没有同名习惯、今天已打过、或出错，都静默返回 undefined。
 */
export async function autoCheckinByName(
  name: string,
): Promise<string | undefined> {
  try {
    const key = name.trim().toLowerCase();
    const habit = (await loadHabits()).find(
      (h) => h.name.toLowerCase() === key,
    );
    if (!habit) return undefined;
    const stamp = stampOf(new Date());
    if ((await loadDone(stamp)).has(habit.id)) return undefined;
    const pending = (await fetchPendingHabits()).find((h) => h.id === habit.id);
    if (!pending) return undefined;
    await checkinHabit(pending);
    return habit.name;
  } catch {
    return undefined;
  }
}

export const habitLabel = (h: Habit) =>
  h.goal > 1 ? `${h.goal}${h.unit}` : "";
