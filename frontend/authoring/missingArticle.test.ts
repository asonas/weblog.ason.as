import assert from "node:assert/strict";
import test from "node:test";
import { redirectMissingArticle } from "./missingArticle";

test("opens a new draft with the missing article title for an editor", async () => {
  for (const title of ["hoge-piyo", "日本語 & 記事", "2026-09-26"]) {
    let destination = "";
    await redirectMissingArticle(
      {
        pathname: `/${encodeURIComponent(title)}`,
        replace: (href) => {
          destination = String(href);
        },
      },
      async (url) => {
        assert.equal(url, "/api/auth/session");
        return Response.json({ can_edit: true });
      },
    );
    const url = new URL(destination, "https://weblog.ason.as");
    assert.equal(url.pathname, "/draft-editor");
    assert.equal(url.searchParams.get("title"), title);
    assert.equal(url.searchParams.has("id"), false);
  }
});

test("keeps the 404 for visitors and when authentication cannot be verified", async () => {
  const fetchers: (typeof fetch)[] = [
    async () => Response.json({ can_edit: false }),
    async () => Response.json({ authenticated: true }),
    async () => new Response(null, { status: 503 }),
    async () => {
      throw new TypeError("offline");
    },
  ];
  for (const fetcher of fetchers) {
    await redirectMissingArticle(
      {
        pathname: "/hoge-piyo",
        replace: () => assert.fail("unexpected redirect"),
      },
      fetcher,
    );
  }
});
