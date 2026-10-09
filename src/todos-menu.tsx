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
import { TODOS_LIST_QUERY } from "./entry-flags";
import { setPendingOpen } from "./pending-open";
import {
  ProjectMenuRow,
  readProjectRows,
  recheckStaleProjects,
} from "./project-menu";
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
import {
  setProjectStatus,
  setStaleDays,
  STALE_CHOICES,
  STATUS_LABEL,
  STATUS_ORDER,
} from "./watchlist";

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
  const [projects, setProjects] = useState<ProjectMenuRow[]>([]);

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
      readProjectRows()
        .then((rows) => alive && setProjects(rows))
        .catch(() => undefined);
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
      // 缓存里判为「该推进」的项目，统计旧了就重算一次，避免白提醒
      recheckStaleProjects()
        .then((rows) => alive && rows && setProjects(rows))
        .catch(() => undefined);
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

  async function openProject(action: "log" | "page" | "add", keyword?: string) {
    await setPendingOpen({ action, keyword });
    await launchCommand({
      name: "notes",
      arguments: { query: TODOS_LIST_QUERY },
      type: LaunchType.UserInitiated,
    });
  }

  async function changeStatus(
    keyword: string,
    status: (typeof STATUS_ORDER)[number],
  ) {
    await setProjectStatus(keyword, status);
    setProjects(await readProjectRows());
    await showHUD(
      `「${keyword}」已设为${STATUS_LABEL[status]}${status === "paused" ? "，不再提醒" : ""}`,
    );
  }

  async function changeStale(keyword: string, days: number) {
    await setStaleDays(keyword, days);
    setProjects(await readProjectRows());
    await showHUD(`「${keyword}」超过 ${days} 天没提及会提醒`);
  }

  const projectMenu = (r: ProjectMenuRow, withGap: boolean) => (
    <MenuBarExtra.Submenu
      key={r.item.keyword}
      title={
        withGap && r.gap !== null
          ? `${r.item.keyword} · ${r.gap} 天没碰`
          : r.item.keyword
      }
      icon={Icon.Pin}
    >
      <MenuBarExtra.Item
        title="记一条"
        icon={Icon.Pencil}
        onAction={() => openProject("log", r.item.keyword)}
      />
      <MenuBarExtra.Item
        title="打开项目主页"
        icon={Icon.House}
        onAction={() => openProject("page", r.item.keyword)}
      />
      <MenuBarExtra.Submenu
        title={`状态：${STATUS_LABEL[r.item.status]}`}
        icon={Icon.Tag}
      >
        {STATUS_ORDER.map((st) => (
          <MenuBarExtra.Item
            key={st}
            title={`${STATUS_LABEL[st]}${st === r.item.status ? "（当前）" : ""}`}
            onAction={() => changeStatus(r.item.keyword, st)}
          />
        ))}
      </MenuBarExtra.Submenu>
      <MenuBarExtra.Submenu
        title={`提醒：${r.item.staleDays} 天没碰`}
        icon={Icon.Bell}
      >
        {STALE_CHOICES.map((d) => (
          <MenuBarExtra.Item
            key={d}
            title={`${d} 天${d === r.item.staleDays ? "（当前）" : ""}`}
            onAction={() => changeStale(r.item.keyword, d)}
          />
        ))}
      </MenuBarExtra.Submenu>
    </MenuBarExtra.Submenu>
  );

  const staleProjects = projects.filter((r) => r.stale);
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
              onAction={() => checkin(h)}
            />
          ))}
        </MenuBarExtra.Section>
      )}
      {staleProjects.length > 0 && (
        <MenuBarExtra.Section title={`项目 · 该推进 ${staleProjects.length}`}>
          {staleProjects.slice(0, 6).map((r) => projectMenu(r, true))}
        </MenuBarExtra.Section>
      )}
      {empty && (
        <MenuBarExtra.Section>
          <MenuBarExtra.Item title="今天没有待办 ✓" />
        </MenuBarExtra.Section>
      )}
      <MenuBarExtra.Section>
        <MenuBarExtra.Submenu
          title={`项目管理${projects.length ? ` (${projects.length})` : ""}`}
          icon={Icon.Pin}
        >
          {projects.map((r) => projectMenu(r, false))}
          <MenuBarExtra.Item
            title="新增项目…"
            icon={Icon.Plus}
            onAction={() => openProject("add")}
          />
        </MenuBarExtra.Submenu>
        <MenuBarExtra.Item
          title="打开待办列表"
          icon={Icon.List}
          onAction={() =>
            launchCommand({
              name: "notes",
              arguments: { query: TODOS_LIST_QUERY },
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
