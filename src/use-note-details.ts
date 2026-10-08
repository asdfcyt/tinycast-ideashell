import { useCallback, useRef, useState } from "react";
import { getNoteDetail, NoteDetail } from "./api";

/**
 * 按需加载并缓存笔记正文：列表选中某条时调用 load(id)，
 * 右侧预览区即可显示完整内容。
 */
export function useNoteDetails() {
  const [details, setDetails] = useState<Record<string, NoteDetail>>({});
  const [loadingId, setLoadingId] = useState<string | null>(null);
  const requested = useRef(new Set<string>());

  const load = useCallback(async (id?: string | null) => {
    if (!id || requested.current.has(id)) return;
    requested.current.add(id);
    setLoadingId(id);
    try {
      const detail = await getNoteDetail(id);
      setDetails((prev) => ({ ...prev, [id]: detail }));
    } catch {
      requested.current.delete(id); // 允许下次选中时重试
    } finally {
      setLoadingId((cur) => (cur === id ? null : cur));
    }
  }, []);

  /** 后台预取一批笔记正文（不影响右侧预览的加载状态），限制并发 */
  const prefetch = useCallback(async (ids: string[], concurrency = 4) => {
    const queue = ids.filter((id) => id && !requested.current.has(id));
    queue.forEach((id) => requested.current.add(id));
    const worker = async () => {
      for (let id = queue.shift(); id; id = queue.shift()) {
        try {
          const detail = await getNoteDetail(id);
          setDetails((prev) => ({ ...prev, [id]: detail }));
        } catch {
          requested.current.delete(id);
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, worker));
  }, []);

  const reset = useCallback(() => {
    requested.current.clear();
    setDetails({});
    setLoadingId(null);
  }, []);

  return { details, loadingId, load, prefetch, reset };
}
