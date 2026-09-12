import { useEffect, useState } from "react";
import "./diaryNavigation.css";

type Neighbors = { newer: string | null; older: string | null };

function dateLabel(date: string) {
  const [year, month, day] = date.split("-");
  return `${year}年${Number(month)}月${Number(day)}日`;
}

export function DiaryNavigation({ route }: { route: string }) {
  const [result, setResult] = useState<(Neighbors & { route: string }) | null>(
    null,
  );
  useEffect(() => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(route)) return;
    const controller = new AbortController();
    async function load() {
      try {
        const response = await fetch(
          `/api/diary-navigation?${new URLSearchParams({ route })}`,
          { signal: controller.signal },
        );
        if (!response.ok) return;
        const neighbors: Neighbors = await response.json();
        if (!controller.signal.aborted) setResult({ ...neighbors, route });
      } catch {
        // Reading the article remains available when navigation cannot load.
      }
    }
    void load();
    return () => controller.abort();
  }, [route]);

  if (!result || result.route !== route || (!result.newer && !result.older))
    return null;

  return (
    <nav className="diary-navigation" aria-label="日記の前後">
      {result.newer ? (
        <a href={`/${result.newer}`} className="diary-navigation__newer">
          <span>← 次の日記</span>
          <time dateTime={result.newer}>{dateLabel(result.newer)}</time>
        </a>
      ) : (
        <span className="diary-navigation__end">最新の日記です</span>
      )}
      {result.older ? (
        <a href={`/${result.older}`} className="diary-navigation__older">
          <span>前の日記 →</span>
          <time dateTime={result.older}>{dateLabel(result.older)}</time>
        </a>
      ) : (
        <span className="diary-navigation__end diary-navigation__older">
          最初の日記です
        </span>
      )}
    </nav>
  );
}
