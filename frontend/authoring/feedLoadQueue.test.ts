/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { FeedLoadQueue, type FeedLoadRequest } from "./feedLoadQueue";

test("loads the last selected month after pagination finishes", async () => {
  const queue = new FeedLoadQueue();
  const requests: FeedLoadRequest[] = [];
  let finishPagination: (() => void) | undefined;
  const load = async (request: FeedLoadRequest) => {
    requests.push(request);
    if (request.direction === "newer") {
      await new Promise<void>((resolve) => {
        finishPagination = resolve;
      });
    }
  };

  const pagination = queue.run(
    { url: "/api/pages?after=cursor", direction: "newer" },
    load,
  );
  await queue.run(
    { url: "/api/pages?month=2026-06", direction: "replace" },
    load,
  );
  await queue.run(
    { url: "/api/pages?month=2026-05", direction: "replace" },
    load,
  );
  finishPagination?.();
  await pagination;

  assert.deepEqual(requests, [
    { url: "/api/pages?after=cursor", direction: "newer" },
    { url: "/api/pages?month=2026-05", direction: "replace" },
  ]);
});
