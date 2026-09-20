export type DraftRoute = {
  kind: "administration" | "editor";
  state: "pending" | "available" | "unavailable";
};

export function resolveDraftRoute(
  pathname: string,
  options: {
    deploymentEnvironment: string;
    authenticationPending: boolean;
    draftAuthoring: boolean;
    localDraft: boolean;
  },
): DraftRoute | null {
  const kind =
    pathname === "/authoring/articles"
      ? "administration"
      : pathname === "/draft-editor"
        ? "editor"
        : null;
  if (!kind) return null;
  if (
    options.deploymentEnvironment === "production" &&
    options.authenticationPending
  )
    return { kind, state: "pending" };
  if (
    options.deploymentEnvironment === "production" &&
    !options.draftAuthoring &&
    !options.localDraft
  )
    return { kind, state: "unavailable" };
  return { kind, state: "available" };
}
