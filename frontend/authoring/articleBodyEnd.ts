// 本文の下にある感想リンクより下に差し込む。感想リンクをdata-public-universeの後ろに置く保存版HTMLでは本文の直後に差し込む
export function insertAfterArticleBody(article: Element, element: Element) {
  const body = article.querySelector(".editor-canvas");
  if (!body) return false;
  const feedback = article.querySelector(":scope > .article-feedback");
  const universe = article.querySelector("[data-public-universe]");
  const feedbackBelowBody =
    feedback &&
    universe &&
    feedback.compareDocumentPosition(universe) &
      feedback.DOCUMENT_POSITION_FOLLOWING;
  (feedbackBelowBody ? feedback : body).after(element);
  return true;
}
