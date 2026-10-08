import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getNoteId, getRecentNotes, NoteInfo, searchNotes } from "./api";
import { buildNoteMarkdown, dayGroup, formatDateTime, shortTime } from "./utils";
import { useNoteDetails } from "./use-note-details";
import { NoteDetailView } from "./note-detail-view";

const GROUP_ORDER = ["今天", "昨天", "最近 7 天", "更早"];

export default function Command() {
  const [notes, setNotes] = useState<NoteInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");
  const { details, loadingId, load } = useNoteDetails();

  const isSearching = searchText.trim().length > 0;

  const loadNotes = useCallback(
    async (query: string) => {
      setIsLoading(true);
      try {
        const results = query.trim() ? await searchNotes(query) : await getRecentNotes({ limit: 20 });
        setNotes(results);
        if (results.length > 0) load(getNoteId(results[0]));
      } catch (error) {
        await showToast({
          style: Toast.Style.Failure,
          title: "搜索失败",
          message: error instanceof Error ? error.message : String(error),
        });
      } finally {
        setIsLoading(false);
      }
    },
    [load],
  );

  useEffect(() => {
    const timer = setTimeout(() => loadNotes(searchText), 300);
    return () => clearTimeout(timer);
  }, [searchText, loadNotes]);

  // 最近笔记按「今天 / 昨天 / 最近 7 天 / 更早」分组；搜索结果保持相关度顺序
  const sections = useMemo(() => {
    if (isSearching) return [{ title: "搜索结果", notes }];
    const map = new Map<string, NoteInfo[]>();
    for (const n of notes) {
      const g = dayGroup(n.created_at || n.createdAt);
      map.set(g, [...(map.get(g) ?? []), n]);
    }
    return GROUP_ORDER.filter((g) => map.has(g)).map((g) => ({ title: g, notes: map.get(g)! }));
  }, [notes, isSearching]);

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={notes.length > 0}
      searchBarPlaceholder="搜索笔记内容、标题或标签…（留空显示最近笔记）"
      // 由服务端做语义检索，客户端不再按标题二次过滤
      filtering={false}
      onSearchTextChange={setSearchText}
      onSelectionChange={(id) => load(id)}
      throttle
    >
      {sections.map((section) => (
        <List.Section key={section.title} title={section.title} subtitle={`${section.notes.length}`}>
          {section.notes.map((note, index) => {
            const noteId = getNoteId(note) || `note-${index}`;
            const detail = details[noteId];
            const body = detail ? detail.content || detail.body || "" : undefined;
            const summary = detail?.summary || note.summary;
            const created = note.created_at || note.createdAt || detail?.created_at;
            const tags = detail?.tags ?? note.tags ?? [];
            const title = note.title || "无标题";

            return (
              <List.Item
                key={noteId}
                id={noteId}
                title={title}
                icon={Icon.Document}
                accessories={created ? [{ text: shortTime(created) }] : []}
                detail={
                  <List.Item.Detail
                    isLoading={loadingId === noteId}
                    markdown={buildNoteMarkdown({ title, summary, body, loading: loadingId === noteId })}
                    metadata={
                      <List.Item.Detail.Metadata>
                        {created && <List.Item.Detail.Metadata.Label title="创建时间" text={formatDateTime(created)} />}
                        {tags.length > 0 && (
                          <List.Item.Detail.Metadata.TagList title="标签">
                            {tags.slice(0, 8).map((t) => (
                              <List.Item.Detail.Metadata.TagList.Item key={t} text={t} />
                            ))}
                          </List.Item.Detail.Metadata.TagList>
                        )}
                      </List.Item.Detail.Metadata>
                    }
                  />
                }
                actions={
                  <ActionPanel>
                    {getNoteId(note) && (
                      <Action.Push
                        title="查看全文"
                        icon={Icon.Eye}
                        target={<NoteDetailView noteId={getNoteId(note)} title={title} summary={summary} />}
                      />
                    )}
                    {body && (
                      <Action.CopyToClipboard
                        title="复制正文"
                        content={body}
                        shortcut={{ modifiers: ["cmd"], key: "c" }}
                      />
                    )}
                    {summary && (
                      <Action.CopyToClipboard
                        title="复制摘要"
                        content={summary}
                        shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
                      />
                    )}
                    <Action.CopyToClipboard
                      title="复制标题"
                      content={title}
                      shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                    />
                  </ActionPanel>
                }
              />
            );
          })}
        </List.Section>
      ))}
      {notes.length === 0 && !isLoading && (
        <List.EmptyView
          title={isSearching ? "没有找到匹配的笔记" : "暂无笔记"}
          description={isSearching ? "试试其他关键词" : "开始使用闪念贝壳记录灵感吧"}
          icon={Icon.MagnifyingGlass}
        />
      )}
    </List>
  );
}
