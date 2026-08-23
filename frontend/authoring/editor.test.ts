/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { buildInternalUniverseGroups, type EditorBootstrap } from "./editor";

test("includes pages that link to the current route in the internal universe", () => {
  const backlink: EditorBootstrap["linked_pages"][number] = {
    id: "daily-page",
    title: "2026-08-23",
    route: "2026-08-23",
    excerpt: "Calicoについて",
    image_url: null,
    related_by: ["Calico"]
  };

  const groups = buildInternalUniverseGroups("https://calicocat.app/", "Calico", [{
    kind: "wiki",
    name: "Calico",
    pages: [backlink],
    isTopicOnly: false
  }]);

  assert.deepEqual(groups, [{
    kind: "wiki",
    name: "Calico",
    pages: [backlink],
    isTopicOnly: false
  }]);
});
