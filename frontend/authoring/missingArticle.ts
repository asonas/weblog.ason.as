export async function redirectMissingArticle(
  location: Pick<Location, "pathname" | "replace">,
  fetcher: typeof fetch = fetch,
) {
  const route = location.pathname.slice(1).replace(/\/$/, "");
  if (!route || route.includes("/") || route === "404.html") return;

  try {
    const title = decodeURIComponent(route);
    const response = await fetcher("/api/auth/session", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) return;
    const auth: unknown = await response.json();
    if (
      typeof auth !== "object" ||
      auth === null ||
      !("can_edit" in auth) ||
      auth.can_edit !== true
    )
      return;
    location.replace(`/draft-editor?${new URLSearchParams({ title })}`);
  } catch {
    // Keep the public 404 readable when authentication is unavailable.
  }
}

if (typeof window !== "undefined") {
  void redirectMissingArticle(window.location);
}
