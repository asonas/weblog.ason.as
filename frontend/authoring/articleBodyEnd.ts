// 本文直後の感想リンクより下に差し込む。本文が空の記事と、感想リンクを本文直後に置かない保存版HTMLでは本文の直後に差し込む
export function insertAfterArticleBody(article: Element, element: Element) {
  const body = article.querySelector(".editor-canvas");
  if (!body) return false;
  const next = body.nextElementSibling;
  const anchor =
    !body.hasAttribute("hidden") && next?.matches(".article-feedback")
      ? next
      : body;
  anchor.after(element);
  return true;
}
