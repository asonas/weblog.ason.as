import { createRoot } from "react-dom/client";

import { AuthoringEditor, type EditorBootstrap } from "./editor";
import "./styles.css";

const root = document.querySelector<HTMLElement>("#authoring-root");
const data = document.querySelector<HTMLScriptElement>("#authoring-data");

if (root && data) {
  const bootstrap = JSON.parse(data.textContent || "{}") as EditorBootstrap;
  createRoot(root).render(<AuthoringEditor bootstrap={bootstrap} />);
}
