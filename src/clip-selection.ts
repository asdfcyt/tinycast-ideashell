import { Clipboard, getFrontmostApplication, getSelectedText, showHUD } from "@raycast/api";
import { execFileSync } from "child_process";
import { createNote, warmUp } from "./api";
import { analyzeCapture, matchFolder } from "./capture-parse";
import { firstLine } from "./capture-core";
import { getFoldersFast, getFoldersFresh } from "./folders-cache";
import { getDefaultTags, truncate } from "./utils";

interface Arguments {
  note?: string;
}

interface Tab {
  title: string;
  url: string;
}

/** 浏览器 → 取当前标签页的 AppleScript（Firefox 不支持脚本，取不到） */
function tabScript(app: string): string | null {
  if (app === "Safari" || app === "Safari Technology Preview") {
    return `tell application "${app}" to return (URL of front document) & linefeed & (name of front document)`;
  }
  if (/^(Google Chrome|Google Chrome Canary|Chromium|Microsoft Edge|Brave Browser|Vivaldi|Arc|Opera|Dia)$/.test(app)) {
    return `tell application "${app}" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)`;
  }
  return null;
}

function readBrowserTab(app: string): Tab | null | "denied" {
  const script = tabScript(app);
  if (!script) return null;
  try {
    const out = execFileSync("/usr/bin/osascript", ["-e", script], { timeout: 4000, encoding: "utf8" }).toString();
    const [url, ...rest] = out.trim().split(/\r?\n/);
    if (!/^https?:\/\//i.test(url ?? "")) return null;
    return { url, title: rest.join(" ").trim() };
  } catch {
    return "denied";
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

let selectionError = "";

/**
 * 取选中文字，三步：
 * 1. Tinycast 原生 getSelectedText（读辅助功能的 AXSelectedText）。Chrome 等浏览器第一次被查询时才开始构建网页的
 *    辅助功能树，首次常常取不到，所以隔一会儿重试几次；
 * 2. 仍然取不到 → 模拟 ⌘C，读剪贴板里变化后的内容，再把原来的剪贴板文字还原。
 */
async function readSelection(): Promise<string> {
  selectionError = "";
  for (let i = 0; i < 4; i++) {
    try {
      const text = (await getSelectedText()).trim();
      if (text) return text;
      selectionError = "no selection";
    } catch (error) {
      selectionError = error instanceof Error ? error.message : String(error);
      // 没有辅助功能权限时重试没有意义
      if (/permission/i.test(selectionError)) break;
    }
    await sleep(250);
  }

  const before = ((await Clipboard.readText().catch(() => "")) ?? "").toString();
  try {
    execFileSync("/usr/bin/osascript", ["-e", 'tell application "System Events" to keystroke "c" using command down'], {
      timeout: 3000,
    });
  } catch {
    return ""; // 没有「辅助功能」权限等
  }
  for (let i = 0; i < 10; i++) {
    await sleep(80);
    const now = ((await Clipboard.readText().catch(() => "")) ?? "").toString();
    if (now && now !== before) {
      if (before) await Clipboard.copy(before);
      return now.trim();
    }
  }
  return "";
}

const quote = (s: string) =>
  s
    .trim()
    .split(/\r?\n/)
    .map((l) => (l.trim() ? `> ${l}` : ">"))
    .join("\n");

/**
 * 摘录选中内容（无界面，可绑全局快捷键）：
 * 选中文字 + 当前浏览器页面（标题 / 链接）+ 来源应用，一次存成带出处的笔记。
 * 批注参数里可以写想法、#标签、@文件夹。
 */
export default async function Command(props: { arguments: Arguments }) {
  warmUp();
  const extra = analyzeCapture(props.arguments?.note ?? "");

  const app = await getFrontmostApplication().catch(() => null);
  const appName = app?.name ?? "";
  const selection = await readSelection();
  const tab = appName ? readBrowserTab(appName) : null;

  const page = tab && tab !== "denied" ? tab : null;
  if (!selection && !page) {
    const clip = ((await Clipboard.readText().catch(() => "")) ?? "").trim();
    if (!clip) {
      await showHUD(
        tab === "denied"
          ? "没有选中文字，且读不到浏览器页面（请在系统设置 → 隐私与安全性 → 自动化里允许 Tinycast 控制浏览器）"
          : "没有选中文字，也不是浏览器页面",
      );
      return;
    }
    return save(clip, null, appName, extra, tab === "denied");
  }
  return save(selection, page, appName, extra, tab === "denied");
}

async function save(
  text: string,
  page: Tab | null,
  appName: string,
  extra: ReturnType<typeof analyzeCapture>,
  denied: boolean,
) {
  const source = page
    ? `来源：[${page.title || page.url}](${page.url})${appName ? ` · ${appName}` : ""}`
    : appName
      ? `来源：${appName}`
      : "";
  const kindTag = text ? "摘录" : "收藏";
  const noSelection = !text && !!page;
  const title = truncate(page?.title || firstLine(text) || `${kindTag} ${appName}`.trim(), 30);

  const body = [text ? quote(text) : "", extra.body, source].filter(Boolean).join("\n\n");
  const tags = [...new Set([...getDefaultTags(), kindTag, ...extra.tags])];

  let folderId: string | undefined;
  let folderNote = "";
  if (extra.folderName) {
    let folder = matchFolder(extra.folderName, await getFoldersFast());
    if (!folder) folder = matchFolder(extra.folderName, await getFoldersFresh());
    if (folder) {
      folderId = folder.id;
      folderNote = ` 📁${folder.name}`;
    } else {
      folderNote = `（文件夹「${extra.folderName}」不存在，已放在未归档）`;
    }
  }

  // 无界面命令：Tinycast 会自动收起窗口；保存完成后再弹 HUD（不要在保存前主动关窗）
  try {
    await createNote({ title, body, tags, folder: folderId, source: "tinycast" });
    await showHUD(
      `✅ ${kindTag}：${truncate(title, 22)}${noSelection ? `（未取到选中文字：${selectionError || "无"}；请确认 Tinycast 已获得辅助功能权限）` : page ? "" : denied ? "（读不到页面链接，请允许 Tinycast 控制浏览器）" : ""}${folderNote}`,
    );
  } catch (error) {
    await Clipboard.copy(body);
    await showHUD(`❌ 保存失败：${error instanceof Error ? error.message : String(error)}（内容已复制到剪贴板）`);
  }
}
