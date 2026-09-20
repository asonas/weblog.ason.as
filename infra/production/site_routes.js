function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === "/search" || uri === "/authoring/articles" || uri === "/authoring/webmentions" || uri === "/draft-editor" || /^\/editor\/[^/]+\/?$/.test(uri)) {
    request.uri = "/index.html";
  } else if (/^\/[^/]+\/$/.test(uri)) {
    request.uri = uri.slice(0, -1);
  }
  return request;
}
