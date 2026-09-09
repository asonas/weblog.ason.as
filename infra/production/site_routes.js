function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === "/search" || uri === "/authoring/webmentions" || /^\/editor\/[^/]+\/?$/.test(uri)) {
    request.uri = "/index.html";
  } else if (/^\/[^/]+\/$/.test(uri)) {
    request.uri = uri.slice(0, -1);
  }
  return request;
}
