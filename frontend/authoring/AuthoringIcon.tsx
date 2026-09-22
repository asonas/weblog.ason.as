// Regen Icons, MIT: ./regen-icons-LICENSE.txt
// https://github.com/kazdenc/regen-icons/tree/main/svg/outline
const paths = {
  check: "M4 12L7.59 15.59A2 2 0 0 0 10.41 15.59L20 6",
  dots: "M4 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0ZM11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0ZM18 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0Z",
  external:
    "M9 3L5 3A2 2 0 0 0 3 5L3 19A2 2 0 0 0 5 21L19 21A2 2 0 0 0 21 19L21 15M10 14L20.41 3.59M15 3L19 3A2 2 0 0 1 21 5L21 9",
  edit: "M4 18.4L4 16.83A2 2 0 0 1 4.59 15.41L14.59 5.41A2 2 0 0 1 17.41 5.41L18.59 6.59A2 2 0 0 1 18.59 9.41L8.59 19.41A2 2 0 0 1 7.17 20L5.6 20A1.6 1.6 0 0 1 4 18.4ZM13 7L17 11",
  refresh:
    "M17.66 17.66A8 8 0 1 1 12 4M12 4Q17 4 19.5 8.5M14 9L19 9A1 1 0 0 0 20 8L20 3",
};

export function AuthoringIcon({ name }: { name: keyof typeof paths }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name]} />
    </svg>
  );
}
