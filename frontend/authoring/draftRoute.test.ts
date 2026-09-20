import assert from "node:assert/strict";
import test from "node:test";
import { resolveDraftRoute } from "./draftRoute";

test("production draft routes wait for authentication", () => {
  const route = resolveDraftRoute("/authoring/articles", {
    deploymentEnvironment: "production",
    authenticationPending: true,
    draftAuthoring: false,
    localDraft: false,
  });

  assert.deepEqual(route, { kind: "administration", state: "pending" });
});

test("production draft routes become available after authentication", () => {
  const route = resolveDraftRoute("/authoring/articles", {
    deploymentEnvironment: "production",
    authenticationPending: false,
    draftAuthoring: true,
    localDraft: false,
  });

  assert.deepEqual(route, { kind: "administration", state: "available" });
});
