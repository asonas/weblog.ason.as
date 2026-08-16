document.querySelectorAll("[data-card-toggle]").forEach((button) => {
  button.addEventListener("click", () => {
    const card = button.closest(".exploration-card");
    const body = card?.querySelector(".post-body");
    if (!card || !body) return;

    const compact = body.classList.toggle("post-body--compact");
    card.classList.toggle("card--compact", compact);
    button.textContent = compact ? "展開" : "折りたたむ";
    button.setAttribute("aria-expanded", String(!compact));
  });
});
