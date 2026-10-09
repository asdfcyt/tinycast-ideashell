import {
  Action,
  ActionPanel,
  closeMainWindow,
  Form,
  Icon,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { runCapture } from "./capture-run";
import { loadKnownTagsCached, refreshKnownTags } from "./known-tags";
import { addWatch, setProjectTags, WatchItem } from "./watchlist";

/** 给关注项「记一条」：预填关键词，保存规则与 Smart Capture 相同（自动分流为待办 / Daily Note / 笔记） */
export function WatchLogForm({ keyword }: { keyword: string }) {
  const [saving, setSaving] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const text = String(values.text ?? "").trim();
    if (!text || text === `${keyword}：`) {
      await showToast({ style: Toast.Style.Failure, title: "请输入内容" });
      return;
    }
    setSaving(true);
    try {
      await showHUD(await runCapture({ text }));
      await closeMainWindow({ clearRootSearch: true });
    } catch (error) {
      setSaving(false);
      await showToast({
        style: Toast.Style.Failure,
        title: "保存失败",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle={`记一条 · ${keyword}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="text"
        title="内容"
        defaultValue={`${keyword}：`}
        placeholder="记点什么…（同样支持 待办 / 日记 / 笔记 前缀、#标签、@文件夹）"
        autoFocus
      />
    </Form>
  );
}

const splitTags = (text: string) =>
  text
    .split(/[\s,，、]+/)
    .map((t) => t.replace(/^#+/, "").trim())
    .filter(Boolean);

/**
 * 新增项目（或编辑已有项目的标签）：
 * 关键词 + 若干闪念贝壳标签一起定义「什么算这件事」——笔记里出现关键词、或带这些标签，都算一次提及。
 */
export function WatchAddForm({ edit }: { edit?: WatchItem } = {}) {
  const { pop } = useNavigation();
  const [known, setKnown] = useState<string[]>([]);
  const [loadingTags, setLoadingTags] = useState(true);
  const [picked, setPicked] = useState<string[]>(edit?.tags ?? []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const cached = await loadKnownTagsCached();
      if (cancelled) return;
      setKnown(cached.tags);
      if (!cached.stale) return setLoadingTags(false);
      try {
        const fresh = await refreshKnownTags();
        if (!cancelled) setKnown(fresh);
      } catch {
        // 取不到就用缓存 / 手动输入
      } finally {
        if (!cancelled) setLoadingTags(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleSubmit(values: Form.Values) {
    const keyword =
      edit?.keyword ??
      String(values.keyword ?? "")
        .trim()
        .replace(/^[#@]+/, "");
    if (!keyword) {
      await showToast({ style: Toast.Style.Failure, title: "请输入关键词" });
      return;
    }
    const tags = [...new Set([...picked, ...splitTags(String(values.extra ?? ""))])];
    if (edit) {
      await setProjectTags(keyword, tags);
      await showToast({ style: Toast.Style.Success, title: `已更新「${keyword}」的标签` });
      pop();
      return;
    }
    const added = await addWatch(keyword, tags);
    await showToast({
      style: added ? Toast.Style.Success : Toast.Style.Failure,
      title: added ? `已添加项目「${keyword}」` : `「${keyword}」已经是项目了`,
    });
    if (added) pop();
  }

  const options = [...new Set([...known, ...picked])];

  return (
    <Form
      isLoading={loadingTags}
      navigationTitle={edit ? `编辑标签 · ${edit.keyword}` : "新增项目"}
      actions={
        <ActionPanel>
          <Action.SubmitForm title={edit ? "保存" : "添加项目"} icon={Icon.Pin} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      {edit ? (
        <Form.Description title="项目" text={edit.keyword} />
      ) : (
        <Form.TextField id="keyword" title="项目关键词" placeholder="如：篆刻、洛神赋、体重、某个人" autoFocus />
      )}
      <Form.TagPicker id="tags" title="标签" value={picked} onChange={setPicked}>
        {options.map((t) => (
          <Form.TagPicker.Item key={t} value={t} title={`#${t}`} />
        ))}
      </Form.TagPicker>
      <Form.TextField id="extra" title="其他标签" placeholder="没有列出的标签，用空格或逗号分隔（可不填）" />
      <Form.Description
        title="说明"
        text="关键词 + 标签一起定义这个项目：笔记里出现关键词、或带这些标签，都算一次提及；待办文字里含它们也归入该项目。标签可多选，列表取自你最近半年笔记里用过的标签。"
      />
    </Form>
  );
}
