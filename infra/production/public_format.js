// Terraformがpublic_markdown_enabledの値に置き換える
var markdownEnabled = false;

function acceptsMarkdown(accept) {
  var values = accept ? (accept.multiValue || [accept]).map(function (entry) { return entry.value; }).join(",") : "";
  return values.split(",").some(function (range) {
    var parts = range.split(";");
    if (parts[0].trim().toLowerCase() !== "text/markdown") return false;
    return !parts.slice(1).some(function (parameter) {
      var weight = /^\s*q\s*=\s*([0-9.]+)\s*$/i.exec(parameter);
      return weight !== null && parseFloat(weight[1]) === 0;
    });
  });
}

function handler(event) {
  var request = event.request;
  var path = request.uri.replace(/\/$/, "");
  var negotiable = markdownEnabled && path !== "/feed.xml" && path !== "/sitemap.xml";
  // 閲覧者が送ったx-weblog-formatは必ず上書きする。残すと任意の値でキャッシュキーを増やせる
  request.headers["x-weblog-format"] = { value: negotiable && acceptsMarkdown(request.headers.accept) ? "markdown" : "html" };
  return request;
}
