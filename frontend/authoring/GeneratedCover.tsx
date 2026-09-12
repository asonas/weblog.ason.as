import { type CSSProperties, useState } from "react";
import { coverPalettes } from "./coverPalettes";

export function GeneratedCover() {
  const [palette] = useState(
    () => coverPalettes[Math.floor(Math.random() * coverPalettes.length)],
  );
  const style: CSSProperties & Record<`--cover-${string}`, string> = {
    "--cover-left": palette[0],
    "--cover-right": palette[1],
  };
  return <div className="generated-cover" style={style} aria-hidden="true" />;
}
