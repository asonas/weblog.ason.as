/// <reference types="node" />

import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer as createHttpServer } from "node:http";
import test from "node:test";

import { createServer } from "vite";

test("rejects removed editor routes", async () => {
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

    assert.equal(response.status, 404);
  } finally {
    await server.close();
  }
});

test("serves development samples and forwards public HTML without loading the home app", async () => {
  const requests: string[] = [];
  const backend = createHttpServer((request, response) => {
    requests.push(request.url || "");
    response.setHeader("Content-Type", "text/html; charset=utf-8");
    response.statusCode = request.url === "/unknown" ? 404 : 200;
    response.end(
      '<html><head></head><body><article>公開本文</article><script type="module" src="/frontend/authoring/publicArticle.ts"></script></body></html>',
    );
  });
  backend.listen(0, "127.0.0.1");
  await once(backend, "listening");
  const address = backend.address();
  assert.ok(address && typeof address !== "string");
  const previousOrigin = process.env.AUTHORING_API_ORIGIN;
  process.env.AUTHORING_API_ORIGIN = `http://127.0.0.1:${address.port}`;
  const server = await createServer({
    server: { host: "127.0.0.1", port: 0, strictPort: false },
  });
  try {
    await server.listen();
    const origin = server.resolvedUrls?.local[0];
    assert.ok(origin);
    const get = (path: string) =>
      fetch(new URL(path, origin), { headers: { Accept: "text/html" } });
    assert.equal((await get("/design-system")).status, 200);
    for (const route of ["/%E8%A8%98%E4%BA%8B", "/KORG%20multi%2Fpoly"]) {
      const response = await get(route);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /公開本文/);
      assert.match(html, /@vite\/client/);
      assert.doesNotMatch(html, /authoring\/main\.tsx/);
    }
    assert.equal((await get("/unknown")).status, 404);
    assert.equal((await get("/editor/page-id")).status, 404);
    assert.deepEqual(requests, [
      "/%E8%A8%98%E4%BA%8B",
      "/KORG%20multi%2Fpoly",
      "/unknown",
    ]);
  } finally {
    await server.close();
    backend.close();
    if (previousOrigin === undefined) delete process.env.AUTHORING_API_ORIGIN;
    else process.env.AUTHORING_API_ORIGIN = previousOrigin;
  }
});
