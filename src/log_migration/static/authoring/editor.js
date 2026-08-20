(() => {
  const form = document.querySelector("#editor");
  if (!form) return;

  const title = document.querySelector("#title");
  const body = document.querySelector("#body");
  const titleErrors = document.querySelector("#title-errors");
  const bodyErrors = document.querySelector("#body-errors");
  const previewErrors = document.querySelector("#body-preview-errors");
  const preview = document.querySelector("#preview");
  const saveStatus = document.querySelector("#save-status");
  let dirty = false;
  let editVersion = 0;
  let mutationError = "";
  let previewSequence = 0;
  let previewError = "";
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
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "操作を完了できませんでした");
    return result;
  };

  const renderErrors = () => {
    titleErrors.textContent = mutationError;
    bodyErrors.textContent = mutationError;
    previewErrors.textContent = previewError;
    title.toggleAttribute("aria-invalid", Boolean(mutationError));
    body.toggleAttribute("aria-invalid", Boolean(mutationError || previewError));
  };

  const setMutationErrors = (message) => {
    mutationError = message;
    renderErrors();
  };

  const setPreviewErrors = (message) => {
    previewError = message;
    renderErrors();
  };

  const updatePage = (page, savedVersion) => {
    form.dataset.pageId = page.id;
    form.dataset.pageType = page.page_type;
    form.dataset.pageDate = page.date || "";
    form.dataset.pageName = page.name || "";
    form.dataset.expectedUpdatedAt = page.updated_at;
    saveStatus.textContent = `${new Date(page.updated_at).toLocaleString("ja-JP")}・${page.status}`;
    dirty = editVersion !== savedVersion;
    setMutationErrors("");
  };

  const updatePreview = async (sequence) => {
    try {
      const result = await request("/api/preview", payload());
      if (sequence !== previewSequence) return;
      preview.innerHTML = result.html;
      setPreviewErrors(result.errors.join(" "));
    } catch (error) {
      if (sequence !== previewSequence) return;
      setPreviewErrors(error.message);
    }
  };

  const schedulePreview = () => {
    dirty = true;
    editVersion += 1;
    previewSequence += 1;
    const sequence = previewSequence;
    window.clearTimeout(previewTimer);
    previewTimer = window.setTimeout(() => updatePreview(sequence), 300);
  };

  title.addEventListener("input", schedulePreview);
  body.addEventListener("input", schedulePreview);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const savedVersion = editVersion;
    try {
      updatePage(await request("/api/save", payload()), savedVersion);
    } catch (error) {
      saveStatus.textContent = error.message;
      setMutationErrors(error.message);
    }
  });
  document.querySelector("#publish").addEventListener("click", async () => {
    if (dirty) {
      saveStatus.textContent = "先に保存してください";
      return;
    }
    if (!form.dataset.pageId || !window.confirm("この内容を公開しますか？")) return;
    try {
      updatePage(
        await request("/api/publish", {
          page_id: form.dataset.pageId,
          expected_updated_at: form.dataset.expectedUpdatedAt,
        }),
        editVersion,
      );
    } catch (error) {
      saveStatus.textContent = error.message;
      setMutationErrors(error.message);
    }
  });
  document.querySelector("#unpublish").addEventListener("click", async () => {
    if (!form.dataset.pageId) return;
    try {
      updatePage(await request("/api/unpublish", { page_id: form.dataset.pageId }), editVersion);
    } catch (error) {
      saveStatus.textContent = error.message;
    }
  });
  window.addEventListener("beforeunload", (event) => {
    if (dirty) {
      event.preventDefault();
      event.returnValue = "";
    }
  });
  updatePreview(previewSequence);
})();
