// Regen Icons, MIT: ./regen-icons-LICENSE.txt
const licenseUrl = new URL("./regen-icons-LICENSE.txt", import.meta.url).href;

const LINKS = [
  {
    href: "/draft-editor",
    label: "新規",
    name: "新しい下書き",
    path: "M4 18.4L4 16.83A2 2 0 0 1 4.59 15.41L14.59 5.41A2 2 0 0 1 17.41 5.41L18.59 6.59A2 2 0 0 1 18.59 9.41L8.59 19.41A2 2 0 0 1 7.17 20L5.6 20A1.6 1.6 0 0 1 4 18.4ZM13 7L17 11",
  },
  {
    href: "/authoring/articles?daily=1",
    label: "今日",
    name: "今日の日記を書く",
    path: "M5 5H19A2 2 0 0 1 21 7V19A2 2 0 0 1 19 21H5A2 2 0 0 1 3 19V7A2 2 0 0 1 5 5ZM3 10L21 10M8 3L8 7M16 3L16 7M8 15.5L16 15.5M12 13L12 18",
  },
  {
    href: "/authoring/articles",
    label: "記事",
    name: "記事一覧",
    path: "M12.38 3L6.5 3A1.5 1.5 0 0 0 5 4.5L5 19.5A1.5 1.5 0 0 0 6.5 21L17.5 21A1.5 1.5 0 0 0 19 19.5L19 9.62A1.5 1.5 0 0 0 18.56 8.56L13.44 3.44A1.5 1.5 0 0 0 12.38 3ZM13 4L13 8A1 1 0 0 0 14 9L18 9M9 13L15 13M9 17L15 17",
  },
  {
    href: "/",
    label: "ホーム",
    name: "公開サイトへ戻る",
    path: "M4 11L10.68 5.15A2 2 0 0 1 13.32 5.15L20 11M6 10L6 18A2 2 0 0 0 8 20L16 20A2 2 0 0 0 18 18L18 10",
  },
];

export function DraftNavigation() {
  return (
    <nav className="draft-navigation" aria-label="執筆メニュー">
      {LINKS.map((link) => (
        <a
          href={link.href}
          key={link.href}
          aria-label={link.name}
          title={link.name}
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
            <path d={link.path} />
          </svg>
          <span>{link.label}</span>
        </a>
      ))}
      <a
        className="draft-navigation__license"
        href={licenseUrl}
        target="_blank"
        rel="noreferrer"
      >
        Icons
      </a>
    </nav>
  );
}
