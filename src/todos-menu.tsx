import {
  environment,
  Icon,
  launchCommand,
  LaunchType,
  MenuBarExtra,
  showHUD,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { habitLabel, PendingHabit } from "./dida-habits";
import { TodoRow } from "./todo-data";
import {
  checkinFromMenu,
  completeFromMenu,
  isEmptySummary,
  menuTitleOf,
  readSummary,
  refreshSummary,
  subtitleOf,
  TodoSummary,
} from "./todo-summary";

const MAX_OVERDUE = 6;
const MAX_TODAY = 10;

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * 菜单栏待办：常驻显示「今天 N · 逾期 M」，点开列出逾期 / 今天的任务，点一下就标记完成。
 * 后台每隔一段时间自动刷新（package.json 里的 interval），不用打开 Tinycast。
 */
export default function Command() {
  const [summary, setSummary] = useState<TodoSummary | undefined>();
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState<string | undefined>();

  async function load(force: boolean) {
    setLoading(true);
    try {
      setSummary(await refreshSummary(force));
      setFailed(undefined);
    } catch (e) {
      setFailed(errMsg(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    let alive = true;
    (async () => {
      // 先用缓存把菜单画出来，再在后台拉最新的
      const cached = await readSummary();
      if (alive && cached) setSummary(cached);
      try {
        const fresh = await refreshSummary(
          environment.launchType === LaunchType.Background,
        );
        if (alive) setSummary(fresh);
      } catch (e) {
        if (alive) setFailed(errMsg(e));
      } finally {
        if (alive) setLoading(false);
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  async function done(row: TodoRow) {
    try {
      const next = await completeFromMenu(row);
      if (next) setSummary(next);
      await showHUD(`已完成：${row.title}`);
    } catch (e) {
      await showHUD(`完成失败：${errMsg(e)}`);
    }
  }

  const item = (row: TodoRow, overdue: boolean) => (
    <MenuBarExtra.Item
      key={row.key}
      title={row.title}
      subtitle={
        overdue
          ? `${(row.date ?? "").slice(5)} ${row.time ?? ""}`.trim()
          : (row.time ?? "")
      }
      icon={Icon.Circle}
      tooltip="点击标记完成"
      onAction={() => done(row)}
    />
  );

  async function checkin(habit: PendingHabit) {
    try {
      const next = await checkinFromMenu(habit);
      if (next) setSummary(next);
      await showHUD(`已打卡：${habit.name}`);
    } catch (e) {
      await showHUD(`打卡失败：${errMsg(e)}`);
    }
  }

  const empty = summary && isEmptySummary(summary);

  return (
    <MenuBarExtra
      icon={Icon.CheckCircle}
      title={summary ? menuTitleOf(summary) : undefined}
      tooltip={summary ? subtitleOf(summary) : "待办"}
      isLoading={loading}
    >
      {failed && !summary && (
        <MenuBarExtra.Item title={`读取失败：${failed}`} />
      )}
      {summary && summary.overdue.length > 0 && (
        <MenuBarExtra.Section title={`逾期 ${summary.overdue.length}`}>
          {summary.overdue.slice(0, MAX_OVERDUE).map((r) => item(r, true))}
          {summary.overdue.length > MAX_OVERDUE && (
            <MenuBarExtra.Item
              title={`还有 ${summary.overdue.length - MAX_OVERDUE} 条逾期…`}
            />
          )}
        </MenuBarExtra.Section>
      )}
      {summary && summary.today.length > 0 && (
        <MenuBarExtra.Section title={`今天 ${summary.today.length}`}>
          {summary.today.slice(0, MAX_TODAY).map((r) => item(r, false))}
          {summary.today.length > MAX_TODAY && (
            <MenuBarExtra.Item
              title={`还有 ${summary.today.length - MAX_TODAY} 条…`}
            />
          )}
        </MenuBarExtra.Section>
      )}
      {summary && summary.habits.length > 0 && (
        <MenuBarExtra.Section
          title={`习惯 · 今天未打卡 ${summary.habits.length}`}
        >
          {summary.habits.map((h) => (
            <MenuBarExtra.Item
              key={h.id}
              title={h.name}
              subtitle={habitLabel(h)}
              icon={Icon.Repeat}
              tooltip="点击打卡"
              onAction={() => checkin(h)}
            />
          ))}
        </MenuBarExtra.Section>
      )}
      {empty && (
        <MenuBarExtra.Section>
          <MenuBarExtra.Item title="今天没有待办 ✓" />
        </MenuBarExtra.Section>
      )}
      <MenuBarExtra.Section>
        <MenuBarExtra.Item
          title="打开 Todos List"
          icon={Icon.List}
          onAction={() =>
            launchCommand({
              name: "todos-list",
              type: LaunchType.UserInitiated,
            })
          }
        />
        <MenuBarExtra.Item
          title="立即刷新"
          icon={Icon.ArrowClockwise}
          onAction={() => load(true)}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
