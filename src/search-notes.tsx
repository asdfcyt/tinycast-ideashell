import { Action, ActionPanel, Detail, List, showToast, Toast, Icon } from "@raycast/api";
import { useState, useEffect, useCallback } from "react";
import { searchNotes, getRecentNotes, getNoteDetail, NoteInfo, NoteDetail } from "./api";
import { truncate } from "./utils";

export default function Command() {
  const [notes, setNotes] = useState<NoteInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");

  const loadNotes = useCallback(async (query: string) => {
    setIsLoading(true);
    try {
      let results: NoteInfo[];
      if (query.trim()) {
        results = await searchNotes(query);
      } else {
        results = await getRecentNotes({ days: 7 });
      }
      setNotes(results);
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "搜索失败",
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      loadNotes(searchText);
    }, 300);
    return () => clearTimeout(timer);
  }, [searchText, loadNotes]);

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="搜索闪念贝壳笔记..."
      onSearchTextChange={setSearchText}
      throttle
    >
      <List.Section title={searchText ? `搜索: ${searchText}` : "最近的笔记"} subtitle={`${notes.length} 条`}>
        {notes.map((note, index) => (
          <List.Item
            key={note.id || `note-${index}`}
            title={note.title || "无标题"}
            subtitle={note.summary ? truncate(note.summary, 60) : ""}
            icon={Icon.Document}
            accessories={[
              ...(note.folder ? [{ tag: `📁 ${note.folder}` }] : []),
              ...(note.tags
                ? note.tags.slice(0, 3).map((t) => ({ tag: t }))
                : []),
            ]}
            actions={
              <ActionPanel>
                {note.id && (
                  <Action.Push
                    title="查看详情"
                    icon={Icon.Eye}
                    target={<NoteDetailView noteId={note.id} title={note.title} />}
                  />
                )}
                <Action.CopyToClipboard
                  title="复制标题"
                  content={note.title}
                  shortcut={{ modifiers: ["cmd"], key: "c" }}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
      {notes.length === 0 && !isLoading && (
        <List.EmptyView
          title={searchText ? "没有找到匹配的笔记" : "暂无笔记"}
          description={searchText ? "试试其他关键词" : "开始使用闪念贝壳记录灵感吧"}
          icon={Icon.MagnifyingGlass}
        />
      )}
    </List>
  );
}

function NoteDetailView({ noteId, title }: { noteId: string; title: string }) {
  const [detail, setDetail] = useState<NoteDetail | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    getNoteDetail(noteId)
      .then(setDetail)
      .catch(async (err) => {
        await showToast({
          style: Toast.Style.Failure,
          title: "加载详情失败",
          message: err instanceof Error ? err.message : String(err),
        });
      })
      .finally(() => setIsLoading(false));
  }, [noteId]);

  const markdown = detail
    ? `# ${detail.title}\n\n${detail.body || "*（空白笔记）*"}`
    : `# ${title}\n\n加载中...`;

  return (
    <Detail
      isLoading={isLoading}
      markdown={markdown}
      metadata={
        detail ? (
          <Detail.Metadata>
            {detail.summary && <Detail.Metadata.Label title="摘要" text={detail.summary} />}
            {detail.tags && detail.tags.length > 0 && (
              <Detail.Metadata.TagList title="标签">
                {detail.tags.map((tag) => (
                  <Detail.Metadata.TagList.Item key={tag} text={tag} />
                ))}
              </Detail.Metadata.TagList>
            )}
            {detail.folder && <Detail.Metadata.Label title="文件夹" text={detail.folder} />}
            {detail.createdAt && <Detail.Metadata.Label title="创建时间" text={detail.createdAt} />}
            {detail.updatedAt && <Detail.Metadata.Label title="更新时间" text={detail.updatedAt} />}
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        <ActionPanel>
          {detail?.body && (
            <Action.CopyToClipboard
              title="复制正文"
              content={detail.body}
              shortcut={{ modifiers: ["cmd"], key: "c" }}
            />
          )}
          <Action.CopyToClipboard
            title="复制标题"
            content={detail?.title || title}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
        </ActionPanel>
      }
    />
  );
}
