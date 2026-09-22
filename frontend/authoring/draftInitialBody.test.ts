import assert from "node:assert/strict";
import test from "node:test";
import {
  storeDraftInitialBody,
  takeDraftInitialBody,
} from "./draftInitialBody";

function memoryStorage(): Pick<Storage, "getItem" | "setItem" | "removeItem"> {
  const values = new Map<string, string>();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
}

test("hands a new daily draft body to the editor once", () => {
  const storage = memoryStorage();
  const body = "[[月曜日]] [[202609]] [[0921]] [[日記]]";

  storeDraftInitialBody(storage, "daily-id", body);

  assert.equal(takeDraftInitialBody(storage, "daily-id", ""), body);
  assert.equal(takeDraftInitialBody(storage, "daily-id", ""), null);
});

test("does not replace an existing draft body", () => {
  const storage = memoryStorage();
  storeDraftInitialBody(storage, "daily-id", "[[日記]]");

  assert.equal(takeDraftInitialBody(storage, "daily-id", "本文"), null);
  assert.equal(takeDraftInitialBody(storage, "daily-id", ""), null);
});
