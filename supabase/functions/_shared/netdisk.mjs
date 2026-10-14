import { createHash } from "node:crypto";
import { fail, json, PublicError, b64, unb64 } from "./font-validation.mjs";
export { fail, json, PublicError };

export function configuration(environment) {
  return {
    supabaseURL: environment.get("SUPABASE_URL"), anonKey: environment.get("SUPABASE_ANON_KEY"), serviceKey: environment.get("SUPABASE_SERVICE_ROLE_KEY"),
    appKey: environment.get("BAIDU_APP_KEY"), secretKey: environment.get("BAIDU_SECRET_KEY"),
    encryptionKey: environment.get("BAIDU_TOKEN_ENCRYPTION_KEY"), root: environment.get("BAIDU_APP_ROOT"),
  };
}
export const caught = error => json({ error: error instanceof PublicError ? error.message : "网盘服务暂时不可用，请稍后重试。" }, error instanceof PublicError ? error.status : 503);
export async function requestBody(request) {
  const text = await request.text();
  if (text.length > 15 * 1024 * 1024) fail(413, "上传内容超过容量限制。");
  try { return JSON.parse(text); } catch { fail(400, "请求格式无效。"); }
}
export function publicFont(row) {
  const extension = row.file_name.split(".").at(-1).toLowerCase();
  return { id: row.id, displayName: row.display_name, fileName: row.file_name, path: `fonts/files/${row.id}.${extension}`,
    size: row.size, sha256: row.sha256, postScriptNames: row.post_script_names, uploadedAt: row.uploaded_at };
}

export class NetdiskBackend {
  constructor(config, deps = {}) { this.config = config; this.fetch = deps.fetch ?? fetch; this.crypto = deps.crypto ?? crypto; this.now = deps.now ?? (() => Date.now()); }
  async database(path, method = "GET", body, prefer) {
    const c = this.config;
    if (!c.supabaseURL || !c.serviceKey) fail(503, "账号后台尚未配置。");
    const response = await this.fetch(`${c.supabaseURL}/rest/v1/${path}`, {
      method, headers: { apikey: c.serviceKey, Authorization: `Bearer ${c.serviceKey}`, "Content-Type": "application/json", ...(prefer ? { Prefer: prefer } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(30000)
    });
    if (!response.ok) fail(503, "无法保存或读取云端数据，请检查后台数据库配置。");
    const text = await response.text(); return text ? JSON.parse(text) : null;
  }
  async authenticate(request, admin = false) {
    const authorization = request.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) fail(401, "请先登录邮箱账号。");
    const response = await this.fetch(`${this.config.supabaseURL}/auth/v1/user`, { headers: { apikey: this.config.anonKey, Authorization: authorization }, signal: AbortSignal.timeout(30000) });
    if (!response.ok) fail(401, "登录已过期，请重新登录。");
    const user = await response.json();
    if (!/^[0-9a-f-]{36}$/i.test(user.id) || !user.email_confirmed_at) fail(403, "请先验证邮箱。");
    if (admin) {
      const rows = await this.database(`font_admins?user_id=eq.${user.id}&select=user_id`);
      if (!rows?.some(row => row.user_id === user.id)) fail(403, "只有字体库管理员可以执行此操作。");
    }
    return user;
  }
  async catalog() {
    const rows = await this.database("font_library?select=*&order=uploaded_at.desc&limit=10000");
    return { schemaVersion: 1, fonts: rows.map(publicFont) };
  }
  async encryptionKey() {
    const value = this.config.encryptionKey;
    if (!/^[0-9a-f]{64}$/i.test(value ?? "")) fail(503, "后台网盘凭证加密尚未配置。");
    const bytes = Uint8Array.from(value.match(/../g), pair => parseInt(pair, 16));
    return this.crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
  }
  async encrypt(tokens) {
    const iv = this.crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await this.crypto.subtle.encrypt({ name: "AES-GCM", iv }, await this.encryptionKey(), new TextEncoder().encode(JSON.stringify(tokens)));
    return { iv: b64(iv), ciphertext: b64(new Uint8Array(ciphertext)) };
  }
  async decrypt(value) {
    try {
      const bytes = await this.crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(value.iv) }, await this.encryptionKey(), unb64(value.ciphertext));
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch { fail(503, "无法读取后台网盘授权，请管理员重新连接。"); }
  }
  async exchange(parameters) {
    const c = this.config;
    if (!c.appKey || !c.secretKey) fail(503, "百度网盘开放平台应用尚未配置。");
    const url = new URL("https://openapi.baidu.com/oauth/2.0/token");
    for (const [key, value] of Object.entries({ ...parameters, client_id: c.appKey, client_secret: c.secretKey })) url.searchParams.set(key, value);
    const response = await this.fetch(url, { signal: AbortSignal.timeout(30000), redirect: "error" });
    const data = await response.json();
    if (!response.ok || data.error || !data.access_token || !data.refresh_token || !Number.isFinite(data.expires_in) || data.expires_in <= 0) fail(502, "百度网盘授权失败，请重新授权或检查后台应用配置。");
    if (data.scope && !data.scope.split(/[ ,]+/).includes("netdisk")) fail(403, "百度账号未授权网盘访问权限，请重新连接。");
    return { accessToken: data.access_token, refreshToken: data.refresh_token, expiresAt: this.now() + data.expires_in * 1000 };
  }
  async saveTokens(tokens) {
    const encrypted = await this.encrypt(tokens);
    await this.database("baidu_connections?on_conflict=id", "POST", { id: "font-library", encrypted_tokens: encrypted, refresh_lock_until: null }, "resolution=merge-duplicates");
  }
  async connection() {
    const rows = await this.database("baidu_connections?id=eq.font-library&select=encrypted_tokens");
    if (!rows?.[0]) fail(409, "管理员尚未连接百度网盘。");
    return this.decrypt(rows[0].encrypted_tokens);
  }
  async accessToken() {
    let tokens = await this.connection();
    if (tokens.expiresAt > this.now() + 60000) return tokens.accessToken;
    const claimed = await this.database("rpc/claim_baidu_refresh", "POST", {});
    if (!claimed) fail(503, "网盘授权正在刷新，请稍后重试。");
    try {
      // Re-read after acquiring the lease so a concurrent completed refresh is
      // never overwritten using an older, already-consumed refresh credential.
      tokens = await this.connection();
      if (tokens.expiresAt <= this.now() + 60000) {
        tokens = await this.exchange({ grant_type: "refresh_token", refresh_token: tokens.refreshToken });
        await this.saveTokens(tokens);
      }
      return tokens.accessToken;
    } finally { await this.database("rpc/release_baidu_refresh", "POST", {}); }
  }
  async baidu(method, token, parameters = {}, body, route = "file") {
    const url = new URL(`https://pan.baidu.com/rest/2.0/xpan/${route}`);
    url.searchParams.set("method", method); url.searchParams.set("access_token", token);
    for (const [key, value] of Object.entries(parameters)) url.searchParams.set(key, String(value));
    const response = await this.fetch(url, {
      method: body ? "POST" : "GET", ...(body ? { body: new URLSearchParams(body) } : {}),
      headers: { "User-Agent": "pan.baidu.com" }, signal: AbortSignal.timeout(60000), redirect: "error"
    });
    const result = await response.json();
    if (!response.ok || result.errno !== 0) fail(502, "百度网盘请求失败，请检查授权、应用权限或网盘流量额度。");
    return result;
  }
  async uploadBytes(bytes, font, token) {
    const root = this.config.root;
    if (!root?.startsWith("/apps/") || root.split("/").includes("..") || root.endsWith("/")) fail(503, "百度网盘应用目录尚未正确配置。");
    const extension = font.fileName.split(".").at(-1).toLowerCase();
    const path = `${root}/${font.id}.${extension}`;
    const blocks = [];
    for (let start = 0; start < bytes.length; start += 4 * 1024 * 1024) {
      const block = bytes.subarray(start, Math.min(bytes.length, start + 4 * 1024 * 1024));
      blocks.push({ bytes: block, md5: createHash("md5").update(block).digest("hex") });
    }
    const blockList = JSON.stringify(blocks.map(block => block.md5));
    const prepared = await this.baidu("precreate", token, {}, { path, size: String(bytes.length), isdir: "0", autoinit: "1", block_list: blockList, rtype: "3" });
    if (prepared.return_type !== 2) {
      if (!prepared.uploadid) fail(502, "百度网盘未返回上传任务。");
      const parts = prepared.block_list ?? blocks.map((_, index) => index);
      for (const index of parts) {
        if (!Number.isInteger(index) || index < 0 || index >= blocks.length) fail(502, "百度网盘返回了无效分片序号。");
        const url = new URL("https://d.pcs.baidu.com/rest/2.0/pcs/superfile2");
        for (const [key, value] of Object.entries({ method: "upload", type: "tmpfile", access_token: token, path, uploadid: prepared.uploadid, partseq: index })) url.searchParams.set(key, String(value));
        const form = new FormData(); form.append("file", new Blob([blocks[index].bytes]), "chunk");
        const response = await this.fetch(url, { method: "POST", body: form, signal: AbortSignal.timeout(60000), redirect: "error" });
        const result = await response.json();
        if (!response.ok || (result.errno !== undefined && result.errno !== 0) || result.md5 !== blocks[index].md5) fail(502, "字体分片上传校验失败，请重试。");
      }
      const created = await this.baidu("create", token, {}, { path, size: String(bytes.length), isdir: "0", uploadid: prepared.uploadid, block_list: blockList, rtype: "3" });
      if (!created.fs_id) fail(502, "百度网盘未返回字体文件信息。");
      return { fsID: String(created.fs_id), path };
    }
    // A fast-upload completion may omit fs_id. Resolve that immutable path
    // through the official folder listing instead of guessing a file identity.
    const list = await this.baidu("list", token, { dir: root, order: "name", limit: 1000 });
    const existing = list.list?.find(row => row.path === path);
    if (!existing?.fs_id) fail(502, "字体已上传，但暂时无法确认网盘文件信息，请重试。");
    return { fsID: String(existing.fs_id), path };
  }
  async stream(fontID) {
    const rows = await this.database(`font_files?font_id=eq.${fontID}&select=fs_id,font_library(size,file_name)`);
    const row = rows?.[0];
    if (!row) fail(404, "字体不在已发布的字体库中。");
    const token = await this.accessToken();
    if (!/^[0-9]+$/.test(row.fs_id)) fail(502, "后台网盘文件标识无效。");
    const meta = await this.baidu("filemetas", token, { fsids: `[${row.fs_id}]`, dlink: 1 });
    const link = meta.list?.[0]?.dlink;
    if (!link) fail(502, "暂时无法取得字体下载地址。");
    let url = new URL(link);
    url.protocol = "https:";
    url.searchParams.set("access_token", token);
    for (let redirects = 0; redirects < 6; redirects++) {
      const allowed = [".baidu.com", ".baidupcs.com", ".bcebos.com"].some(suffix => url.hostname.endsWith(suffix));
      if (url.protocol !== "https:" || !allowed) fail(502, "百度网盘返回了无法识别的下载域名。");
      const upstream = await this.fetch(url, { headers: { "User-Agent": "pan.baidu.com" }, redirect: "manual", signal: AbortSignal.timeout(60000) });
      if ([301, 302, 303, 307, 308].includes(upstream.status)) {
        const location = upstream.headers.get("Location");
        if (!location) fail(502, "字体下载重定向无效。");
        await upstream.body?.cancel(); url = new URL(location, url); continue;
      }
      if (!upstream.ok || !upstream.body) fail(502, "字体下载失败，请稍后重试。");
      const size = Number(upstream.headers.get("Content-Length"));
      if (size && size !== row.font_library.size) { await upstream.body.cancel(); fail(502, "网盘字体文件大小已改变，请管理员重新发布。"); }
      // Never return Baidu's dlink or access token to the Mac application.
      return new Response(upstream.body, { headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store", "Content-Length": String(row.font_library.size) } });
    }
    fail(502, "字体下载重定向过多。");
  }
}
