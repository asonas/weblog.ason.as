import { useId, useRef, useState } from "react";
import { localDiaryDate, previousDiaryDate } from "./diaryDate";

// Calendar from Regen Icons (MIT: ./regen-icons-LICENSE.txt) with a back chevron.
const PAST_DIARY_ICON =
  "M5 5H19A2 2 0 0 1 21 7V19A2 2 0 0 1 19 21H5A2 2 0 0 1 3 19V7A2 2 0 0 1 5 5ZM3 10L21 10M8 3L8 7M16 3L16 7M13.5 13L10.5 15.5L13.5 18";

export function PastDiaryAction() {
  const dialog = useRef<HTMLDialogElement>(null);
  const headingId = useId();
  const dateId = useId();
  const hintId = useId();
  const [date, setDate] = useState("");
  const [today, setToday] = useState("");

  function open() {
    const now = new Date();
    setToday(localDiaryDate(now));
    setDate(previousDiaryDate(now));
    dialog.current?.showModal();
  }

  return (
    <>
      <button
        type="button"
        data-action="past-diary"
        aria-haspopup="dialog"
        title="日付を選んで過去の日記を書く"
        onClick={open}
      >
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={PAST_DIARY_ICON} />
        </svg>
        <span>過去の日記を書く</span>
      </button>
      <dialog
        ref={dialog}
        className="past-diary-dialog"
        aria-labelledby={headingId}
      >
        <form
          onSubmit={(event) => {
            event.preventDefault();
            window.location.assign(
              `/authoring/articles?daily=1&date=${encodeURIComponent(date)}`,
            );
          }}
        >
          <h2 id={headingId}>過去の日記を書く</h2>
          <label htmlFor={dateId}>日付</label>
          <input
            id={dateId}
            type="date"
            required
            max={today}
            value={date}
            aria-describedby={hintId}
            onChange={(event) => setDate(event.target.value)}
          />
          <p id={hintId}>
            今日より後の日付は選べません。その日の日記が既にあれば、それを開きます。
          </p>
          <div className="past-diary-dialog__actions">
            <button type="button" onClick={() => dialog.current?.close()}>
              キャンセル
            </button>
            <button type="submit" className="past-diary-dialog__submit">
              日記を書く
            </button>
          </div>
        </form>
      </dialog>
    </>
  );
}
