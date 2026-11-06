import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { setTimeout } from "node:timers/promises";

export default async ({ page, webBase, evidence, shot, step }) => {
  const until = async (check) => {
    for (let i = 0; i < 200; i++) {
      if (await check()) return;
      await setTimeout(100);
    }
    throw new Error("公開状態の更新を待つ間に時間切れになりました。");
  };
  const title = `非同期公開の検証 ${Date.now()}`;
  step("editor-open / editor-save: 新しい記事を作り、タイトルと本文をサーバーへ保存する");
  await page.goto(`${webBase}/draft-editor`);
  const titleField = page.getByRole("textbox", { name: "タイトル", exact: true });
  await titleField.fill(title);
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("公開受付のあと、一覧で結果を確認する本文。");
  await until(async () => (await page.getByRole("status").allTextContents()).some((text) => text.includes("サーバーに保存済み")));
  const editorUrl = page.url();
  const id = new URL(editorUrl).searchParams.get("id");
  const saved = await page.request.get(`${webBase}/api/authoring/drafts/${id}?protocol=1&generation=1&cursor=0`);
  assert.equal((await saved.json()).metadata.title.value, title);
  let lists = 0;
  let runs = 0;
  let acceptancePending = false;
  let manualRetry = false;
  let dispatchPolls = 0;
  let releaseAcceptance;
  const acceptanceGate = new Promise((resolve) => { releaseAcceptance = resolve; });
  // Local generation is synchronous. Delay only acceptance and the list's
  // publication fields to exercise the production worker's visible states.
  await page.route("**/publications", async (route) => {
    acceptancePending = true;
    await acceptanceGate;
    await route.continue();
  });
  await page.route("**/api/authoring/drafts?*", async (route) => {
    const response = await route.fetch();
    const data = await response.json();
    lists++;
    data.articles = data.articles.map((article) => {
      if (article.id === id && manualRetry && dispatchPolls < 2)
        return { ...article, publication: { ...article.publication, stages: article.publication.stages.map((stage) => stage.stage === "search" ? { ...stage, status: "needs_attention", error: "検索の更新に失敗しました。" } : stage) } };
      if (article.id !== id || runs >= 2) return article;
      const phase = lists === 1 ? "accepted" : lists === 2 ? "running" : "cache";
      return { ...article,
        ...(phase !== "cache" ? { state: "draft", public_route: null, published_at: null } : {}),
        publication: { ...article.publication,
          status: phase === "accepted" ? "accepted" : "completed",
          stages: phase === "accepted" ? [] : phase === "running"
            ? [{ stage: "html", status: "running" }]
            : [...article.publication.stages, { stage: "cache", status: "retry_wait", next_attempt_at: new Date(Date.now() - 1000).toISOString(), error: "キャッシュ更新中です。" }],
        },
      };
    });
    await route.fulfill({ response, json: data });
  });
  await page.route("**/publications/*/run", async (route) => {
    if (manualRetry) {
      const response = await route.fetch();
      const data = await response.json();
      await route.fulfill({ response, json: { ...data, dispatch: { id: "manual-retry", status: "queued" } } });
      return;
    }
    runs++;
    if (runs === 1) await route.fulfill({ status: 503, json: { error: "一時的な通信失敗" } });
    else await route.continue();
  });
  await page.route("**/publications/*?dispatch_id=manual-retry", async (route) => {
    dispatchPolls++;
    const response = await route.fetch();
    const data = await response.json();
    await route.fulfill({ response, json: { ...data, dispatch: { id: "manual-retry", status: dispatchPolls < 2 ? "running" : "completed" } } });
  });
  step("editor-publish: 公開受付の応答待ちでは離脱を警告する");
  await shot("before-publication");
  await page.getByRole("button", { name: "公開する", exact: true }).click();
  await until(() => acceptancePending);
  assert.equal(await page.evaluate(() => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  }), true);
  await shot("accepting");
  releaseAcceptance();
  await page.waitForURL("**/authoring/articles");
  assert.equal(runs, 0, "受付後、ブラウザから追加の起動要求を出さず一覧へ移る");
  const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) });
  await row.getByText("公開処理中", { exact: true }).waitFor();
  await shot("accepted-in-list");
  step("admin-publication: 行を自動更新し、cache retry_wait を /run で再確認する。一時失敗も再確認する");
  await until(async () => (await row.textContent()).includes("キャッシュ更新中です。"));
  await shot("cache-pending");
  await until(() => runs >= 2);
  await until(async () => (await row.getByRole("img", { name: "反映済み", exact: true }).count()) === 3);
  await row.getByText("公開中", { exact: true }).waitFor();
  await shot("completed-in-list");
  const settled = lists;
  await setTimeout(3500);
  assert.equal(lists, settled, "未完了の公開がなくなれば一覧の自動更新を停止する");
  assert.equal(runs, 2);
  step("admin-retry: 要対応の行で手動再試行し、worker 起動待ちでも自動更新を続ける");
  manualRetry = true;
  await page.getByRole("button", { name: "再読み込み", exact: true }).click();
  await row.getByText("検索の更新に失敗しました。", { exact: false }).waitFor();
  await row.getByRole("button", { name: `${title}の操作`, exact: true }).click();
  await page.getByRole("menuitem", { name: "公開処理を再試行", exact: true }).click();
  await until(() => dispatchPolls >= 2);
  await until(async () => (await row.getByRole("img", { name: "反映済み", exact: true }).count()) === 3);
  await shot("manual-retry-completed");
  const retrySettled = lists;
  await setTimeout(3500);
  assert.equal(lists, retrySettled, "再試行の dispatch 完了後も自動更新を停止する");
  step("受付後の離脱警告が消え、API の読み直しでも公開完了を確認できる");
  assert.equal(await page.evaluate(() => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  }), false);
  const response = await page.request.get(`${webBase}/api/authoring/drafts?q=${encodeURIComponent(title)}`);
  const published = await response.json();
  assert.equal(published.articles.find((article) => article.id === id).publication.status, "completed");
  writeFileSync(resolve(evidence, "publication-api.json"), JSON.stringify({ editorUrl, lists, runs, dispatchPolls, published }, null, 2));
};
