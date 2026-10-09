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
import { autoCheckinByName } from "./dida-habits";
import { loadKnownTagsCached, refreshKnownTags } from "./known-tags";
import { addWatch, setProjectTags, WatchItem } from "./watchlist";

/**
 * 给项目「记一条」：保存为一条独立的笔记，自动打上项目的关键词 / 标签，
 * 这样它会被归入该项目（不再写入 Daily Note）。需要待办时，在内容前写「待办 …」即可。
 */
export function WatchLogForm({ keyword, tags = [] }: { keyword: string; tags?: string[] }) {
  const [saving, setSaving] = useState(false);
  const projectTags = [...new Set([keyword, ...tags])];

  async function handleSubmit(values: Form.Values) {
    const text = String(values.text ?? "").trim();
    if (!text) {
      await showToast({ style: Toast.Style.Failure, title: "请输入内容" });
      return;
    }
    setSaving(true);
    try {
      const result = await runCapture({ text, defaultKind: "note", extraTags: projectTags });
      // 滴答里有和项目同名的习惯：记一条的同时自动打卡
      const habit = await autoCheckinByName(keyword);
      await showHUD(habit ? `${result} · 已为习惯「${habit}」打卡` : result);
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
        placeholder="记点什么…（保存为独立笔记；也支持 待办 前缀、额外的 #标签、@文件夹）"
        autoFocus
      />
      <Form.Description
        title="自动标签"
        text={`${projectTags.map((t) => `#${t}`).join(" ")}（保存为一条独立的笔记，不写入 Daily Note）`}
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
