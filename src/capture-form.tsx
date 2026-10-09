import { Action, ActionPanel, Clipboard, closeMainWindow, Form, Icon, showHUD, showToast, Toast } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { FolderInfo, warmUp } from "./api";
import { analyzeCapture, CaptureKind, inferFolder, matchFolder } from "./capture-parse";
import { KIND_LABEL, saveCapture } from "./capture-core";
import { getFoldersFast } from "./folders-cache";

const UNFILED = "";

const parseTags = (s: string) => [
  ...new Set(
    s
      .split(/[\s,，、]+/)
      .map((t) => t.replace(/^#+/, ""))
      .filter(Boolean),
  ),
];

/**
 * 万能输入（表单）：Smart Capture 什么都没输入就回车时进入（经由 Template Capture 的「自由输入」）；输入正文时，类型 / 标签 / 文件夹实时自动识别并填好；
 * 一旦你手动改过某一项，该项就不再被自动覆盖（标题上的「自动」标记会消失）。
 */
export function CaptureForm() {
  const [text, setText] = useState("");
  const [kind, setKind] = useState<CaptureKind>("daily");
  const [tags, setTags] = useState("");
  const [folder, setFolder] = useState(UNFILED);
  const [folders, setFolders] = useState<FolderInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [touched, setTouched] = useState({
    kind: false,
    tags: false,
    folder: false,
  });

  // 回调里需要拿到最新的 folders / touched，用 ref 避免闭包过期
  const foldersRef = useRef<FolderInfo[]>([]);
  const touchedRef = useRef(touched);
  touchedRef.current = touched;

  useEffect(() => {
    warmUp(); // 趁你打字的时候先完成 MCP 握手，回车后直接保存
    getFoldersFast()
      .then((list) => {
        foldersRef.current = list;
        setFolders(list);
      })
      .catch(() => {})
      .finally(() => setIsLoading(false));
  }, []);

  function recognize(value: string) {
    setText(value);
    const t = touchedRef.current;
    const a = analyzeCapture(value);
    if (!t.kind) setKind(a.forced ?? (value.trim() ? a.recommended : "daily"));
    if (!t.tags) setTags(a.tags.map((x) => `#${x}`).join(" "));
    if (!t.folder) {
      const list = foldersRef.current;
      const found = a.folderName ? matchFolder(a.folderName, list) : inferFolder(a.body, list);
      setFolder(found?.id ?? UNFILED);
    }
  }

  const a = analyzeCapture(text);
  const hint = (() => {
    if (!text.trim()) return "输入内容后，类型 / 标签 / 文件夹会自动填好；正文留空保存则使用剪贴板。";
    if (kind === "todo") {
      const when = [a.todo.date, a.todo.time].filter(Boolean).join(" ");
      return `📅 待办：${a.todo.content || a.body}${when ? `　⏰ ${when}` : "　（未识别到日期，将创建无日期待办）"}`;
    }
    if (kind === "daily") return "📝 将追加到今天的 Daily Note（标签会写在这一条后面）。";
    return "🗒 将新建笔记，标签写在正文最后一行。";
  })();

  async function handleSubmit() {
    try {
      let source = text;
      let fromClipboard = false;
      if (!source.trim()) {
        source = ((await Clipboard.readText()) ?? "").trim();
        if (!source) throw new Error("请输入内容，或先复制一些文字");
        fromClipboard = true;
      }
      const parsed = analyzeCapture(source);
      if (!parsed.body) throw new Error("没有可保存的内容");

      const finalKind: CaptureKind = fromClipboard && !touched.kind ? "note" : kind;
      const chosen = folders.find((f) => f.id === folder);

      // 注意：不能先关窗——关窗后 Tinycast 会终止扩展，保存和 HUD 都不会执行。
      // 正确顺序：保存完成 → 弹 HUD → 再关窗。
      const toast = await showToast({ style: Toast.Style.Animated, title: "正在保存..." });
      try {
        const message = await saveCapture({
          kind: finalKind,
          body: parsed.body,
          todo: parsed.todo,
          tags: touched.tags || !fromClipboard ? parseTags(tags) : parsed.tags,
          folderId: finalKind === "note" ? chosen?.id : undefined,
          folderNote: finalKind === "note" && chosen ? ` 📁${chosen.name}` : "",
          how: "",
        });
        await showHUD(message);
        await closeMainWindow({ clearRootSearch: true });
      } catch (error) {
        toast.style = Toast.Style.Failure;
        toast.title = "保存失败";
        toast.message = error instanceof Error ? error.message : String(error);
      }
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "保存失败",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const mark = (k: keyof typeof touched) => (touched[k] ? "" : "（自动）");

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
          <Action
            title="全部恢复为自动识别"
            icon={Icon.Wand}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={() => {
              setTouched({ kind: false, tags: false, folder: false });
              touchedRef.current = { kind: false, tags: false, folder: false };
              recognize(text);
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="text"
        title="内容"
        placeholder="记点什么…（支持「待办 / 日记 / 笔记」前缀、#标签、@文件夹；留空 = 剪贴板）"
        value={text}
        onChange={recognize}
      />
      <Form.Description title="识别结果" text={hint} />
      <Form.Separator />
      <Form.Dropdown
        id="kind"
        title={`类型${mark("kind")}`}
        value={kind}
        onChange={(v) => {
          if (v === kind) return;
          setKind(v as CaptureKind);
          setTouched((t) => ({ ...t, kind: true }));
        }}
      >
        {(Object.keys(KIND_LABEL) as CaptureKind[]).map((k) => (
          <Form.Dropdown.Item key={k} value={k} title={KIND_LABEL[k]} />
        ))}
      </Form.Dropdown>
      <Form.TextField
        id="tags"
        title={`标签${mark("tags")}`}
        placeholder="#读书 #思考（多个用空格分隔）"
        value={tags}
        onChange={(v) => {
          if (v === tags) return;
          setTags(v);
          setTouched((t) => ({ ...t, tags: true }));
        }}
      />
      <Form.Dropdown
        id="folder"
        title={`文件夹${mark("folder")}`}
        value={folder}
        onChange={(v) => {
          if (v === folder) return;
          setFolder(v);
          setTouched((t) => ({ ...t, folder: true }));
        }}
      >
        <Form.Dropdown.Item value={UNFILED} title="未归档" />
        {folders.map((f) => (
          <Form.Dropdown.Item key={f.id} value={f.id} title={f.name} />
        ))}
      </Form.Dropdown>
    </Form>
  );
}
