(() => {
  const form = document.querySelector("#editor");
  if (!form) return;

  const title = document.querySelector("#title");
  const body = document.querySelector("#body");
  const preview = document.querySelector("#preview");
  const previewErrors = document.querySelector("#preview-errors");
  const saveStatus = document.querySelector("#save-status");
  let dirty = false;
  let previewTimer;

  const payload = () => ({
    page_id: form.dataset.pageId || undefined,
    page_type: form.dataset.pageType,
    date: form.dataset.pageDate,
    name: form.dataset.pageName || undefined,
    title: title.value,
    body: body.value,
    expected_updated_at: form.dataset.expectedUpdatedAt || undefined,
  });

  const request = async (url, data) => {
    const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "操作を完了できませんでした");
    return result;
  };

  const updatePage = (page) => {
    form.dataset.pageId = page.id;
    form.dataset.pageType = page.page_type;
    form.dataset.pageDate = page.date || "";
    form.dataset.pageName = page.name || "";
    form.dataset.expectedUpdatedAt = page.updated_at;
    saveStatus.textContent = `${new Date(page.updated_at).toLocaleString("ja-JP")}・${page.status}`;
    dirty = false;
  };

  const updatePreview = async () => {
    try {
      const result = await request("/api/preview", payload());
      preview.innerHTML = result.html;
      previewErrors.textContent = result.errors.join(" ");
    } catch (error) {
      previewErrors.textContent = error.message;
    }
  };

  const schedulePreview = () => {
    dirty = true;
    window.clearTimeout(previewTimer);
    previewTimer = window.setTimeout(updatePreview, 300);
  };

  title.addEventListener("input", schedulePreview);
  body.addEventListener("input", schedulePreview);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    try { updatePage(await request("/api/save", payload())); } catch (error) { saveStatus.textContent = error.message; }
  });
  document.querySelector("#publish").addEventListener("click", async () => {
    if (!form.dataset.pageId || !window.confirm("この内容を公開しますか？")) return;
    try { updatePage(await request("/api/publish", { page_id: form.dataset.pageId, expected_updated_at: form.dataset.expectedUpdatedAt })); } catch (error) { saveStatus.textContent = error.message; }
  });
  document.querySelector("#unpublish").addEventListener("click", async () => {
    if (!form.dataset.pageId) return;
    try { updatePage(await request("/api/unpublish", { page_id: form.dataset.pageId })); } catch (error) { saveStatus.textContent = error.message; }
  });
  window.addEventListener("beforeunload", (event) => { if (dirty) { event.preventDefault(); event.returnValue = ""; } });
  updatePreview();
})();
