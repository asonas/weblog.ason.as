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
  const pageName = document.querySelector("#page-name");
  const renameErrors = document.querySelector("#rename-errors");
  const renameButton = document.querySelector("#rename");
  const publishButton = document.querySelector("#publish");
  const unpublishButton = document.querySelector("#unpublish");

  const state = {
    dirty: false,
    editVersion: 0,
    previewSequence: 0,
    previewTimer: null,
  };

  const payload = () => ({
    page_id: form.dataset.pageId || undefined,
    page_type: form.dataset.pageType,
    date: form.dataset.pageDate || undefined,
    name: form.dataset.pageName || undefined,
    title: title.value,
    body: body.value,
    expected_updated_at: form.dataset.expectedUpdatedAt || undefined,
  });

  const request = async (url, data) => {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(data),
    });
    let result;
    try {
      result = await response.json();
    } catch (_error) {
      throw new Error("サーバーからの応答を読み取れませんでした");
    }
    if (!response.ok) {
      const message = result.error || "操作を完了できませんでした";
      const error = new Error(message);
      error.fields = result.errors || {};
      throw error;
    }
    return result;
  };

  const renderErrors = (message = "", previewMessage = "") => {
    titleErrors.textContent = message;
    bodyErrors.textContent = message;
    previewErrors.textContent = previewMessage;
    title.toggleAttribute("aria-invalid", Boolean(message));
    body.toggleAttribute("aria-invalid", Boolean(message || previewMessage));
  };

  const clearRenameError = () => {
    renameErrors.textContent = "";
    pageName.removeAttribute("aria-invalid");
  };

  const focusFirstInvalid = () => {
    const target = document.querySelector("[aria-invalid='true']");
    if (target) target.focus();
  };

  const showMutationError = (error) => {
    saveStatus.textContent = error.message;
    renderErrors(error.message);
    if (error.fields && error.fields.name) {
      renameErrors.textContent = error.fields.name.join(" ");
      pageName.setAttribute("aria-invalid", "true");
    }
    focusFirstInvalid();
  };

  const updatePage = (page, savedVersion) => {
    form.dataset.pageId = page.id || "";
    form.dataset.pageType = page.page_type || form.dataset.pageType;
    form.dataset.pageDate = page.date || "";
    form.dataset.pageName = page.name || "";
    form.dataset.expectedUpdatedAt = page.updated_at || "";
    if (page.name && pageName) pageName.value = page.name;
    saveStatus.textContent = `${page.updated_at || ""}・${page.status || ""}`;
    state.dirty = state.editVersion !== savedVersion;
    renderErrors();
    clearRenameError();
  };

  const updatePreview = async (sequence) => {
    preview.setAttribute("aria-busy", "true");
    try {
      const result = await request("/api/preview", payload());
      if (sequence !== state.previewSequence) return;
      preview.innerHTML = result.html || "";
      previewErrors.textContent = (result.errors || []).join(" ");
      body.toggleAttribute("aria-invalid", (result.errors || []).length > 0);
    } catch (error) {
      if (sequence !== state.previewSequence) return;
      previewErrors.textContent = error.message;
      body.setAttribute("aria-invalid", "true");
    } finally {
      if (sequence === state.previewSequence) preview.setAttribute("aria-busy", "false");
    }
  };

  const schedulePreview = () => {
    state.dirty = true;
    state.editVersion += 1;
    state.previewSequence += 1;
    const sequence = state.previewSequence;
    window.clearTimeout(state.previewTimer);
    state.previewTimer = window.setTimeout(() => updatePreview(sequence), 300);
  };

  title.addEventListener("input", schedulePreview);
  body.addEventListener("input", schedulePreview);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const savedVersion = state.editVersion;
    try {
      updatePage(await request("/api/save", payload()), savedVersion);
    } catch (error) {
      showMutationError(error);
    }
  });

  publishButton.addEventListener("click", async () => {
    if (state.dirty) {
      showMutationError(new Error("先に下書きを保存してください"));
      return;
    }
    if (!form.dataset.pageId || !window.confirm("この内容を公開しますか？")) return;
    try {
      updatePage(
        await request("/api/publish", {
          page_id: form.dataset.pageId,
          expected_updated_at: form.dataset.expectedUpdatedAt || undefined,
        }),
        state.editVersion,
      );
    } catch (error) {
      showMutationError(error);
    }
  });

  unpublishButton.addEventListener("click", async () => {
    if (state.dirty) {
      showMutationError(new Error("先に下書きを保存してください"));
      return;
    }
    if (!form.dataset.pageId || !window.confirm("このページを非公開にしますか？")) return;
    try {
      updatePage(await request("/api/unpublish", { page_id: form.dataset.pageId }), state.editVersion);
    } catch (error) {
      showMutationError(error);
    }
  });

  if (renameButton) {
    renameButton.addEventListener("click", async () => {
      clearRenameError();
      if (state.dirty) {
        renameErrors.textContent = "先に下書きを保存してください";
        pageName.setAttribute("aria-invalid", "true");
        focusFirstInvalid();
        return;
      }
      if (!form.dataset.pageId || !pageName.value.trim()) return;
      try {
        updatePage(
          await request("/api/rename", { page_id: form.dataset.pageId, name: pageName.value }),
          state.editVersion,
        );
      } catch (error) {
        renameErrors.textContent = error.message;
        pageName.setAttribute("aria-invalid", "true");
        focusFirstInvalid();
      }
    });
  }

  window.addEventListener("beforeunload", (event) => {
    if (!state.dirty) return;
    event.preventDefault();
    event.returnValue = "";
  });

  updatePreview(state.previewSequence);
})();
