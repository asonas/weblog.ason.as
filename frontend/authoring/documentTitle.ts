export function articleDocumentTitle(
  title: string,
  environment?: string,
): string {
  const pageTitle = title ? `${title} | weblog.ason.as` : "weblog.ason.as";
  return environment === "development" ? `[dev] ${pageTitle}` : pageTitle;
}
