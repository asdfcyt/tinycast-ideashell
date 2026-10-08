import { Action, ActionPanel, Detail, List, showToast, Toast, Icon } from "@raycast/api";
import { useState, useEffect, useCallback } from "react";
import { searchNotes, getRecentNotes, getNoteDetail, NoteInfo, NoteDetail, getNoteId } from "./api";
import { formatDateTime } from "./utils";
import { useNoteDetails } from "./use-note-details";

function buildMarkdown(title: string, body: string | undefined, summary: string | undefined, loading: boolean): string {
  if (body === undefined) {
    const hint = summary ? `${summary}\n\n*${loading ? "加载全文中…" : "选中后加载全文"}*` : loading ? "加载中…" : "";
    return `# ${title}\n\n${hint}`;
  }
  return `# ${title}\n\n${body.trim() || summary || "*（空白笔记）*"}`;
}

export default function Command() {
  const [notes, setNotes] = useState<NoteInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");
  const { details, loadingId, load } = useNoteDetails();

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
    const timer = setTimeout(() => {
      loadNotes(searchText);
    }, 300);
    return () => clearTimeout(timer);
  }, [searchText, loadNotes]);

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={notes.length > 0}
      searchBarPlaceholder="搜索笔记内容、标题或标签..."
      // 搜索由服务端语义检索完成，不要再让客户端按标题二次过滤
      filtering={false}
      onSearchTextChange={setSearchText}
      onSelectionChange={(id) => load(id)}
      throttle
    >
      <List.Section title={searchText.trim() ? "搜索结果" : "最近的笔记"} subtitle={`${notes.length} 条`}>
        {notes.map((note, index) => {
          const noteId = getNoteId(note);
          const detail = details[noteId];
          const body = detail ? detail.content || detail.body || "" : undefined;
          const created = note.created_at || note.createdAt;

          return (
            <List.Item
              key={noteId || `note-${index}`}
              id={noteId || `note-${index}`}
              title={note.title || "无标题"}
              icon={Icon.Document}
              accessories={created ? [{ text: formatDateTime(created).slice(5) }] : []}
              detail={
                <List.Item.Detail
                  isLoading={loadingId === noteId}
                  markdown={buildMarkdown(note.title || "无标题", body, note.summary, loadingId === noteId)}
                  metadata={
                    <List.Item.Detail.Metadata>
                      {created && <List.Item.Detail.Metadata.Label title="创建时间" text={formatDateTime(created)} />}
                      {note.folder && <List.Item.Detail.Metadata.Label title="文件夹" text={note.folder} />}
                      {(detail?.tags ?? note.tags) && (detail?.tags ?? note.tags)!.length > 0 && (
                        <List.Item.Detail.Metadata.TagList title="标签">
                          {(detail?.tags ?? note.tags)!.slice(0, 8).map((t) => (
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
                  {noteId && (
                    <Action.Push
                      title="查看全文"
                      icon={Icon.Eye}
                      target={<NoteDetailView noteId={noteId} title={note.title} />}
                    />
                  )}
                  {body && (
                    <Action.CopyToClipboard
                      title="复制正文"
                      content={body}
                      shortcut={{ modifiers: ["cmd"], key: "c" }}
                    />
                  )}
                  <Action.CopyToClipboard
                    title="复制标题"
                    content={note.title}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                  />
                </ActionPanel>
              }
            />
          );
        })}
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

  const noteBody = detail ? detail.content || detail.body || "" : "";

  return (
    <Detail
      isLoading={isLoading}
      markdown={buildMarkdown(detail?.title || title, detail ? noteBody : undefined, undefined, isLoading)}
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
            {detail.created_at && (
              <Detail.Metadata.Label title="创建时间" text={formatDateTime(detail.created_at)} />
            )}
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        <ActionPanel>
          {noteBody && (
            <Action.CopyToClipboard
              title="复制正文"
              content={noteBody}
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
