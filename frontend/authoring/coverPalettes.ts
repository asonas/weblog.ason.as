// Seven analogous pairs and three OKLCH complements, within sRGB.
// Chroma is 62% / 56% of the gamut limit (46% for complementary accents).
export const coverPalettes: readonly (readonly [string, string])[] = [
  ["oklch(0.84 0.072 65)", "oklch(0.86 0.043 35)"],
  ["oklch(0.84 0.056 35)", "oklch(0.86 0.044 5)"],
  ["oklch(0.84 0.051 285)", "oklch(0.86 0.057 315)"],
  ["oklch(0.84 0.049 275)", "oklch(0.86 0.041 245)"],
  ["oklch(0.84 0.058 235)", "oklch(0.86 0.082 205)"],
  ["oklch(0.84 0.089 195)", "oklch(0.86 0.101 165)"],
  ["oklch(0.84 0.062 355)", "oklch(0.86 0.071 325)"],
  ["oklch(0.84 0.072 65)", "oklch(0.86 0.034 245)"],
  ["oklch(0.84 0.089 195)", "oklch(0.86 0.035 15)"],
  ["oklch(0.84 0.058 235)", "oklch(0.86 0.041 55)"],
];
