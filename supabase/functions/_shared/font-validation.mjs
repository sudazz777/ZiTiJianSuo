export const MAX_UPLOAD_SIZE = 10 * 1024 * 1024;
export class PublicError extends Error { constructor(status, message) { super(message); this.status = status; } }
export const fail = (status, message) => { throw new PublicError(status, message); };
export const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
export const unb64 = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
export const b64 = bytes => { let text = ""; for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(text); };
function validateFontBytes(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const face = offset => {
    if (offset + 12 > bytes.length) fail(400, "字体文件结构无效。");
    const magic = view.getUint32(offset);
    if (![0x00010000, 0x4f54544f, 0x74727565].includes(magic)) fail(400, "文件不是支持的字体格式。");
    const tables = view.getUint16(offset + 4);
    if (!tables || tables > 4096 || offset + 12 + tables * 16 > bytes.length) fail(400, "字体文件结构无效。");
    for (let i = 0; i < tables; i++) {
      const record = offset + 12 + i * 16;
      const start = view.getUint32(record + 8), length = view.getUint32(record + 12);
      if (start + length > bytes.length) fail(400, "字体表超出文件范围。");
    }
  };
  if (bytes.length < 12) fail(400, "字体文件过短。");
  if (view.getUint32(0) === 0x74746366) {
    const count = view.getUint32(8);
    if (!count || count > 256 || 12 + count * 4 > bytes.length) fail(400, "字体集合结构无效。");
    for (let i = 0; i < count; i++) face(view.getUint32(12 + i * 4));
  } else face(0);
}

export async function prepareFont(input, cryptoAPI = crypto, now = Date.now()) {
  if (!input || typeof input.fileName !== "string" || input.fileName.length > 240 || /[\/\\\x00-\x1f]/.test(input.fileName)) fail(400, "字体文件名无效。");
  const extension = input.fileName.split(".").at(-1).toLowerCase();
  if (!["ttf", "otf", "ttc"].includes(extension)) fail(400, "请选择 TTF、OTF 或 TTC 字体。");
  if (typeof input.displayName !== "string" || !input.displayName.trim() || input.displayName.length > 160) fail(400, "字体显示名称无效。");
  if (typeof input.content !== "string" || input.content.length > 4 * Math.ceil(MAX_UPLOAD_SIZE / 3) || !/^[A-Za-z0-9+/]*={0,2}$/.test(input.content)) fail(400, "字体内容无效或超过 10 MiB。");
  let bytes;
  try { bytes = unb64(input.content); } catch { fail(400, "字体编码无效。"); }
  if (!bytes.length || bytes.length > MAX_UPLOAD_SIZE) fail(400, "字体内容无效或超过 10 MiB。");
  validateFontBytes(bytes);
  const postScriptNames = input.postScriptNames ?? [];
  if (!Array.isArray(postScriptNames) || postScriptNames.length > 256 || postScriptNames.some(n => typeof n !== "string" || n.length > 240)) fail(400, "字体名称信息无效。");
  const digest = new Uint8Array(await cryptoAPI.subtle.digest("SHA-256", bytes));
  const hash = Array.from(digest, b => b.toString(16).padStart(2, "0")).join("");
  return { id: hash, displayName: input.displayName.trim(), fileName: input.fileName, path: `fonts/files/${hash}.${extension}`, size: bytes.length, sha256: hash, postScriptNames, uploadedAt: new Date(now).toISOString() };
}

