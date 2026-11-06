// 記事一覧から新しい記事を書き始め、タイトルと本文がサーバーに保存され、再読み込み後も残ることを確かめる。
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { setTimeout } from "node:timers/promises";

async function until(check, message) {
  for (let i = 0; i < 200; i++) { if (await check()) return; await setTimeout(100); }
  assert.fail(`Timed out: ${message}`);
}

export default async ({ page, context, webBase, evidence, shot, step }) => {
  const title = `検証 ${Date.now()}`;
  const body = "検証スキルで書いた本文";
  step("記事一覧を開く");
  await page.goto(`${webBase}/authoring/articles`);
  const menu = page.getByRole("navigation", { name: "執筆メニュー" });
  await menu.waitFor();
  await shot("articles");

  step("執筆メニューの「新しい記事を書く」から編集画面へ移る");
  await menu.getByRole("link", { name: "新しい記事を書く" }).click();
  const titleField = page.getByLabel("タイトル", { exact: true });
  await until(async () => await titleField.isEnabled().catch(() => false), "タイトル欄が編集可能になる");
  await titleField.fill(title);
  await page.getByRole("textbox", { name: "本文", exact: true }).fill(body);
  await until(() => new URL(page.url()).searchParams.has("id"), "URLに記事IDが付く");
  const id = new URL(page.url()).searchParams.get("id");
  await shot("typed");

  step(`画面の状態表示が「サーバーに保存済み」になるのを待つ id=${id}`);
  await until(async () => (await page.getByRole("status").allTextContents()).some(text => text.includes("サーバーに保存済み")), "サーバーに保存済み");
  let saved;
  await until(async () => {
    const response = await page.request.get(`${webBase}/api/authoring/drafts/${id}?protocol=1&generation=1&cursor=0`);
    if (!response.ok()) return false;
    saved = await response.json();
    return saved.metadata?.title?.value === title;
  }, "APIのタイトルが入力値になる");
  writeFileSync(resolve(evidence, "draft-api.json"), JSON.stringify(saved, null, 2));

  step("再読み込みしても入力が残る");
  await page.reload();
  await until(async () => (await page.getByLabel("タイトル", { exact: true }).inputValue().catch(() => "")) === title, "再読み込み後のタイトル");
  await until(async () => (await page.getByRole("textbox", { name: "本文", exact: true }).inputValue().catch(() => "")) === body, "再読み込み後の本文");
  await shot("reloaded");

  step("端末内データを持たない別のブラウザコンテキストでも、サーバーから本文が復元される");
  const other = await context.browser().newContext({ viewport: { width: 1440, height: 960 }, locale: "ja-JP" });
  try {
    const reopened = await other.newPage();
    await reopened.goto(page.url());
    await until(async () => (await reopened.getByRole("textbox", { name: "本文", exact: true }).inputValue().catch(() => "")) === body, "別コンテキストの本文");
    assert.equal(await reopened.getByLabel("タイトル", { exact: true }).inputValue(), title);
    await reopened.screenshot({ path: resolve(evidence, "other-context.png"), fullPage: true });
  } finally {
    await other.close();
  }

  step("記事一覧に保存した記事が載る");
  await page.goto(`${webBase}/authoring/articles`);
  await page.getByRole("region", { name: "記事一覧", exact: true }).getByRole("link", { name: title, exact: true }).waitFor();
  await shot("listed");
};
