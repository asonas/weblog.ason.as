import assert from "node:assert/strict";
import test from "node:test";
import {
  localDiaryDate,
  previousDiaryDate,
  requestedDiaryDate,
} from "./diaryDate";

test("formats the device's local calendar day", () => {
  assert.equal(localDiaryDate(new Date(2026, 10, 9, 23, 59)), "2026-11-09");
});

test("defaults past diaries to the previous day across month and year boundaries", () => {
  assert.equal(previousDiaryDate(new Date(2026, 10, 9, 0, 1)), "2026-11-08");
  assert.equal(previousDiaryDate(new Date(2026, 10, 1)), "2026-10-31");
  assert.equal(previousDiaryDate(new Date(2027, 0, 1)), "2026-12-31");
  assert.equal(previousDiaryDate(new Date(2028, 2, 1)), "2028-02-29");
  assert.equal(previousDiaryDate(new Date(2027, 2, 1)), "2027-02-28");
});

test("accepts a requested diary date up to today", () => {
  const now = new Date(2026, 10, 9, 12);
  assert.equal(requestedDiaryDate("2026-11-08", now), "2026-11-08");
  assert.equal(requestedDiaryDate("2026-11-09", now), "2026-11-09");
  assert.equal(requestedDiaryDate("2020-02-29", now), "2020-02-29");
});

test("falls back to today for missing, malformed, impossible, or future dates", () => {
  const now = new Date(2026, 10, 9, 12);
  for (const value of [
    null,
    "",
    "2026-11-10",
    "2027-01-01",
    "2026-02-30",
    "2026-13-01",
    "2026-1-01",
    "yesterday",
  ])
    assert.equal(requestedDiaryDate(value, now), "2026-11-09", String(value));
});
