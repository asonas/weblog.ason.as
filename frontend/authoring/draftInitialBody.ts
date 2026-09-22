type DraftInitialBodyStorage = Pick<
  Storage,
  "getItem" | "setItem" | "removeItem"
>;

function key(id: string) {
  return `draft-initial-body:${id}`;
}

export function storeDraftInitialBody(
  storage: DraftInitialBodyStorage,
  id: string,
  body: string,
) {
  storage.setItem(key(id), body);
}

export function takeDraftInitialBody(
  storage: DraftInitialBodyStorage,
  id: string,
  currentBody: string,
) {
  const body = storage.getItem(key(id));
  if (body === null) return null;
  storage.removeItem(key(id));
  return currentBody.length === 0 ? body : null;
}
