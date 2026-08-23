export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
export const MAX_IMAGE_PIXELS = 80_000_000;
export const MAX_LONG_EDGE = 2560;

export type ImageDimensions = { width: number; height: number };

function uint24(data: DataView, offset: number): number {
  return data.getUint8(offset) | (data.getUint8(offset + 1) << 8) | (data.getUint8(offset + 2) << 16);
}

function exifOrientation(data: DataView, offset: number, length: number): number | null {
  const payload = offset + 2;
  const end = offset + length;
  if (payload + 14 > end) return null;
  if (data.getUint32(payload) !== 0x45786966 || data.getUint16(payload + 4) !== 0) return null;

  const tiff = payload + 6;
  const byteOrder = data.getUint16(tiff);
  if (byteOrder !== 0x4949 && byteOrder !== 0x4d4d) return null;
  const littleEndian = byteOrder === 0x4949;
  if (data.getUint16(tiff + 2, littleEndian) !== 42) return null;

  const directory = tiff + data.getUint32(tiff + 4, littleEndian);
  if (directory + 2 > end) return null;
  const entries = data.getUint16(directory, littleEndian);
  for (let index = 0; index < entries; index += 1) {
    const entry = directory + 2 + index * 12;
    if (entry + 12 > end) return null;
    if (data.getUint16(entry, littleEndian) === 0x0112) return data.getUint16(entry + 8, littleEndian);
  }
  return null;
}

function jpegDimensions(data: DataView): ImageDimensions | null {
  if (data.byteLength < 4 || data.getUint16(0) !== 0xffd8) return null;
  let offset = 2;
  let orientation = 1;
  while (offset + 8 < data.byteLength) {
    if (data.getUint8(offset) !== 0xff) return null;
    const marker = data.getUint8(offset + 1);
    offset += 2;
    if (marker === 0xd8 || marker === 0xd9) continue;
    if (offset + 2 > data.byteLength) return null;
    const length = data.getUint16(offset);
    if (length < 2 || offset + length > data.byteLength) return null;
    if (marker === 0xe1) orientation = exifOrientation(data, offset, length) ?? orientation;
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      const dimensions = { height: data.getUint16(offset + 3), width: data.getUint16(offset + 5) };
      return orientation >= 5 && orientation <= 8
        ? { width: dimensions.height, height: dimensions.width }
        : dimensions;
    }
    offset += length;
  }
  return null;
}

function webpDimensions(data: DataView): ImageDimensions | null {
  if (data.byteLength < 30) return null;
  const ascii = (offset: number, length: number) =>
    String.fromCharCode(...Array.from({ length }, (_, index) => data.getUint8(offset + index)));
  if (ascii(0, 4) !== "RIFF" || ascii(8, 4) !== "WEBP") return null;
  const chunk = ascii(12, 4);
  if (chunk === "VP8X") return { width: uint24(data, 24) + 1, height: uint24(data, 27) + 1 };
  if (chunk === "VP8L" && data.getUint8(20) === 0x2f) {
    const b1 = data.getUint8(21);
    const b2 = data.getUint8(22);
    const b3 = data.getUint8(23);
    const b4 = data.getUint8(24);
    return {
      width: 1 + b1 + ((b2 & 0x3f) << 8),
      height: 1 + (b2 >> 6) + (b3 << 2) + ((b4 & 0x0f) << 10)
    };
  }
  if (chunk === "VP8 " && data.getUint8(23) === 0x9d && data.getUint8(24) === 0x01 && data.getUint8(25) === 0x2a) {
    return { width: data.getUint16(26, true) & 0x3fff, height: data.getUint16(28, true) & 0x3fff };
  }
  return null;
}

export function imageDimensions(buffer: ArrayBuffer, contentType: string): ImageDimensions | null {
  const data = new DataView(buffer);
  if (contentType === "image/png" && data.byteLength >= 24 && data.getUint32(0) === 0x89504e47) {
    return { width: data.getUint32(16), height: data.getUint32(20) };
  }
  if (contentType === "image/gif" && data.byteLength >= 10) {
    return { width: data.getUint16(6, true), height: data.getUint16(8, true) };
  }
  if (contentType === "image/jpeg") return jpegDimensions(data);
  if (contentType === "image/webp") return webpDimensions(data);
  return null;
}

export function resizedDimensions({ width, height }: ImageDimensions): ImageDimensions {
  const longEdge = Math.max(width, height);
  if (longEdge <= MAX_LONG_EDGE) return { width, height };
  const scale = MAX_LONG_EDGE / longEdge;
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}
