const DIARY_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

export function localDiaryDate(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

export function previousDiaryDate(now: Date): string {
  return localDiaryDate(
    new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1),
  );
}

// Returns the requested date only when it is a real calendar day no later than
// today; anything else falls back to today's diary.
export function requestedDiaryDate(value: string | null, now: Date): string {
  const today = localDiaryDate(now);
  const match = value ? DIARY_DATE.exec(value) : null;
  if (!value || !match) return today;
  const [, year, month, day] = match.map(Number);
  const parsed = new Date(year, month - 1, day);
  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  )
    return today;
  return value > today ? today : value;
}
