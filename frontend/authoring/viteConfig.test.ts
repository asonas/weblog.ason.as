/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { createServer } from "vite";

test("serves editor routes as SPA pages", async () => {
  const server = await createServer({
    server: { host: "127.0.0.1", port: 0, strictPort: false },
  });

  try {
    await server.listen();
    const origin = server.resolvedUrls?.local[0];
    assert.ok(origin);

    const response = await fetch(new URL("editor/page-id", origin), {
      headers: { Accept: "text/html" },
    });

    assert.equal(response.status, 200);
    assert.match(await response.text(), /id="authoring-root"/);
  } finally {
    await server.close();
  }
});
