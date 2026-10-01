export type MentionedDays = {
  days: { day: string; pieces: { id: string; href: string; html: string }[] }[];
  cursor: string | null;
};

export function mountMentionedByDays(
  article: HTMLElement,
  enhance: (root: HTMLElement) => void,
  fetcher: typeof fetch = fetch,
  initial?: MentionedDays,
) {
  const universe = article.querySelector<HTMLElement>("[data-public-universe]");
  if (!universe?.dataset.publicUniverse) return;
  const route: unknown = JSON.parse(universe.dataset.publicUniverse).route;
  if (typeof route !== "string") return;
  const section = document.createElement("section");
  section.className = "mentioned-by-days";
  section.setAttribute("aria-labelledby", "mentioned-by-days-heading");
  section.hidden = true;
  const heading = document.createElement("h2");
  heading.id = "mentioned-by-days-heading";
  heading.textContent = "Mentioned by days";
  const content = document.createElement("div");
  const status = document.createElement("p");
  status.setAttribute("role", "status");
  const more = document.createElement("button");
  more.type = "button";
  more.textContent = "もっと見る";
  more.hidden = true;
  section.append(heading, content, status, more);
  article.querySelector(".editor-canvas")?.after(section);
  let cursor: string | undefined;
  const load = async () => {
    more.disabled = true;
    status.textContent = "";
    try {
      const query = new URLSearchParams({ route });
      if (cursor) query.set("before", cursor);
      let result = initial;
      initial = undefined;
      if (!result) {
        const response = await fetcher(`/api/mentioned-by-days?${query}`, {
          cache: "no-store",
        });
        if (!response.ok) throw new Error("言及を読み込めませんでした");
        result = (await response.json()) as MentionedDays;
      }
      for (const day of result.days) {
        const group = document.createElement("section");
        group.className = "mentioned-by-days__day";
        for (const piece of day.pieces) {
          const entry = document.createElement("figure");
          entry.className = "mentioned-by-days__piece";
          const source = document.createElement("figcaption");
          const link = document.createElement("a");
          link.href = piece.href;
          const date = document.createElement("time");
          date.dateTime = day.day;
          date.textContent = day.day;
          link.append(date, "の日記を見る");
          source.append(link);
          const quote = document.createElement("blockquote");
          quote.cite = piece.href;
          const body = document.createElement("div");
          body.className = "ProseMirror public-article-body";
          // HTML is rendered by the same server-side sanitizer as article bodies.
          body.innerHTML = piece.html;
          quote.append(body);
          entry.append(source, quote);
          group.append(entry);
          enhance(entry);
        }
        content.append(group);
      }
      cursor = result.cursor || undefined;
      section.hidden = content.childElementCount === 0;
      more.hidden = !cursor;
      more.textContent = "もっと見る";
    } catch {
      section.hidden = false;
      status.textContent = "言及を読み込めませんでした。";
      more.hidden = false;
      more.textContent = "再試行";
    } finally {
      more.disabled = false;
    }
  };
  more.addEventListener("click", () => void load());
  void load();
}
