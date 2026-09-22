import { useId, useRef, useState } from "react";
import { AuthoringIcon } from "./AuthoringIcon";

export function DraftArticleMenu({
  title,
  editHref,
  busy,
  onRetry,
}: {
  title: string;
  editHref: string;
  busy: boolean;
  onRetry?: () => void;
}) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const popup = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const items = () =>
    Array.from(
      popup.current?.querySelectorAll<HTMLElement>(
        '[role="menuitem"]:not(:disabled)',
      ) || [],
    );
  const show = (last = false) => {
    const box = popup.current;
    if (!box || !trigger.current) return;
    box.showPopover();
    const rect = trigger.current.getBoundingClientRect();
    box.style.left = `${Math.max(8, Math.min(rect.right - box.offsetWidth, window.innerWidth - box.offsetWidth - 8))}px`;
    box.style.top = `${rect.bottom + box.offsetHeight + 8 > window.innerHeight ? Math.max(8, rect.top - box.offsetHeight - 4) : rect.bottom + 4}px`;
    const entries = items();
    (last ? entries.at(-1) : entries[0])?.focus({ preventScroll: true });
  };
  const close = () => {
    popup.current?.hidePopover();
    trigger.current?.focus();
  };
  return (
    <div className="draft-article-menu">
      <button
        ref={trigger}
        type="button"
        className="draft-admin-icon"
        aria-label={`${title}の操作`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => (open ? close() : show())}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            show(event.key === "ArrowUp");
          }
        }}
      >
        <AuthoringIcon name="dots" />
      </button>
      <div
        ref={popup}
        id={id}
        popover="auto"
        role="menu"
        aria-label={`${title}の操作`}
        className="draft-article-menu__popup"
        onToggle={(event) => {
          setOpen(event.newState === "open");
        }}
        onKeyDown={(event) => {
          const entries = items();
          const index = entries.indexOf(document.activeElement as HTMLElement);
          if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
            event.preventDefault();
            const next =
              event.key === "Home"
                ? 0
                : event.key === "End"
                  ? entries.length - 1
                  : (index +
                      (event.key === "ArrowDown" ? 1 : -1) +
                      entries.length) %
                    entries.length;
            entries[next]?.focus();
          } else if (event.key === "Escape") {
            event.preventDefault();
            close();
          } else if (event.key === "Tab") {
            popup.current?.hidePopover();
            trigger.current?.focus();
          }
        }}
      >
        <a role="menuitem" tabIndex={-1} href={editHref}>
          <AuthoringIcon name="edit" />
          編集
        </a>
        {onRetry && (
          <button
            role="menuitem"
            tabIndex={-1}
            type="button"
            disabled={busy}
            onClick={() => {
              close();
              onRetry();
            }}
          >
            <AuthoringIcon name="refresh" />
            公開処理を再試行
          </button>
        )}
      </div>
    </div>
  );
}
