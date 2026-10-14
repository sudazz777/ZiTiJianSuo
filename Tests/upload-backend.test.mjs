import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { prepareFont } from "../supabase/functions/_shared/font-validation.mjs";
import { NetdiskBackend } from "../supabase/functions/_shared/netdisk.mjs";
import { handleUpload } from "../supabase/functions/font-admin-upload/handler.mjs";
import { handleConnect } from "../supabase/functions/font-baidu-connect/handler.mjs";

const userID = "11111111-1111-1111-1111-111111111111";
const config = { supabaseURL: "https://test.supabase.co", anonKey: "test-public", serviceKey: "test-service", appKey: "test-baidu-app", secretKey: "test-baidu-secret", encryptionKey: "42".repeat(32), root: "/apps/TestFontFinder" };
const respond = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", ...headers } });
const bytes = new Uint8Array(44), view = new DataView(bytes.buffer);
view.setUint32(0, 0x00010000); view.setUint16(4, 1); view.setUint32(12, 0x68656164); view.setUint32(20, 28); view.setUint32(24, 16);
const input = { fileName: "Test.ttf", displayName: "Test Font", postScriptNames: ["Test-Regular"], content: Buffer.from(bytes).toString("base64") };
const request = body => new Request("https://test.supabase.co/functions/v1/test", { method: "POST", headers: { Authorization: "Bearer test-email-session", "Content-Type": "application/json" }, body: JSON.stringify(body) });
const authorized = (url, admin = true) => {
  if (new URL(url).pathname === "/auth/v1/user") return respond({ id: userID, email_confirmed_at: new Date().toISOString() });
  if (new URL(url).pathname.endsWith("/font_admins")) return respond(admin ? [{ user_id: userID }] : []);
  return null;
};

test("font preparation checks paths, real table bounds and content checksum", async () => {
  const font = await prepareFont(input);
  assert.equal(font.sha256, createHash("sha256").update(bytes).digest("hex"));
  assert.equal(font.size, bytes.length);
  await assert.rejects(prepareFont({ ...input, fileName: "../Test.ttf" }));
  await assert.rejects(prepareFont({ ...input, content: Buffer.from("not a font").toString("base64") }));
  const broken = bytes.slice(); new DataView(broken.buffer).setUint32(24, 999999);
  await assert.rejects(prepareFont({ ...input, content: Buffer.from(broken).toString("base64") }));
});

test("provider credentials are encrypted with authenticated encryption", async () => {
  const backend = new NetdiskBackend(config);
  const token = { accessToken: "test-provider-access", refreshToken: "test-provider-refresh", expiresAt: Date.now() + 100000 };
  const encrypted = await backend.encrypt(token);
  assert(!JSON.stringify(encrypted).includes(token.accessToken));
  assert.deepEqual(await backend.decrypt(encrypted), token);
  const damaged = { ...encrypted, ciphertext: encrypted.ciphertext.slice(0, -4) + "AAAA" };
  await assert.rejects(backend.decrypt(damaged));
});

test("anonymous uploads and unverified emails never reach netdisk", async () => {
  let calls = 0;
  const anonymous = new Request("https://test.supabase.co/test", { method: "POST", body: "{}" });
  assert.equal((await handleUpload(anonymous, config, { fetch: async () => { calls++; throw new Error(); } })).status, 401);
  assert.equal(calls, 0);
  const response = await handleUpload(request(input), config, { fetch: async () => respond({ id: userID, email_confirmed_at: null }) });
  assert.equal(response.status, 403);
});

test("normal email accounts cannot upload or connect provider account", async () => {
  const fetch = async url => { const result = authorized(url, false); assert(result); return result; };
  assert.equal((await handleUpload(request(input), config, { fetch })).status, 403);
  assert.equal((await handleConnect(request({ action: "start" }), config, { fetch })).status, 403);
});

test("OAuth start binds one-time state to authenticated administrator", async () => {
  let saved;
  const fetch = async (url, options) => {
    const result = authorized(url); if (result) return result;
    assert(new URL(url).pathname.endsWith("/baidu_oauth_states"));
    saved = JSON.parse(options.body); return new Response(null, { status: 201 });
  };
  const response = await handleConnect(request({ action: "start" }), config, { fetch });
  assert.equal(response.status, 200);
  const body = await response.json(), url = new URL(body.authorizationURL);
  assert.equal(url.hostname, "openapi.baidu.com");
  assert.equal(url.searchParams.get("response_type"), "code");
  assert.equal(url.searchParams.get("redirect_uri"), "oob");
  assert.equal(url.searchParams.get("state"), saved.state);
  assert.equal(saved.user_id, userID);
  assert(!JSON.stringify(body).includes(config.secretKey));
});

test("expired or replayed OAuth state cannot exchange any code", async () => {
  const fetch = async (url, options) => {
    const result = authorized(url); if (result) return result;
    assert(new URL(url).pathname.endsWith("/baidu_oauth_states"));
    assert.equal(options.method, "DELETE"); return respond([]);
  };
  const response = await handleConnect(request({ action: "complete", state: userID, code: "test-once" }), config, { fetch });
  assert.equal(response.status, 400);
});

test("OAuth completion consumes state then stores encrypted provider credentials", async () => {
  let consumed = false, stored;
  const fetch = async (url, options) => {
    const result = authorized(url); if (result) return result;
    const target = new URL(url);
    if (target.pathname.endsWith("/baidu_oauth_states")) {
      assert(target.searchParams.get("user_id").includes(userID)); consumed = true; return respond([{ state: userID }]);
    }
    if (target.hostname === "openapi.baidu.com") {
      assert(consumed); assert.equal(target.searchParams.get("client_secret"), config.secretKey);
      return respond({ access_token: "provider-access", refresh_token: "provider-refresh", expires_in: 3600, scope: "basic netdisk" });
    }
    if (target.pathname.endsWith("/baidu_connections")) { stored = JSON.parse(options.body); return new Response(null, { status: 201 }); }
    throw new Error("Unexpected request");
  };
  const response = await handleConnect(request({ action: "complete", state: userID, code: "test-code" }), config, { fetch });
  assert.deepEqual(await response.json(), { connected: true });
  assert.equal((await new NetdiskBackend(config).decrypt(stored.encrypted_tokens)).accessToken, "provider-access");
});

test("expired credentials cannot be refreshed concurrently without a lease", async () => {
  const backend = new NetdiskBackend(config);
  const encrypted = await backend.encrypt({ accessToken: "expired", refreshToken: "old-refresh", expiresAt: 0 });
  backend.fetch = async url => {
    const target = new URL(url);
    if (target.pathname.endsWith("/baidu_connections")) return respond([{ encrypted_tokens: encrypted }]);
    assert(target.pathname.endsWith("/claim_baidu_refresh")); return respond(false);
  };
  await assert.rejects(backend.accessToken());
});

test("chunk upload uses official endpoints and verifies each chunk digest", async () => {
  const font = await prepareFont(input), steps = [];
  const backend = new NetdiskBackend(config, { fetch: async (url, options) => {
    const target = new URL(url); steps.push(target.searchParams.get("method"));
    if (target.searchParams.get("method") === "precreate") {
      assert.equal(target.hostname, "pan.baidu.com");
      assert.deepEqual(JSON.parse(options.body.get("block_list")), [createHash("md5").update(bytes).digest("hex")]);
      return respond({ errno: 0, return_type: 1, uploadid: "test-upload", block_list: [0] });
    }
    if (target.searchParams.get("method") === "upload") {
      assert.equal(target.hostname, "d.pcs.baidu.com");
      const uploaded = new Uint8Array(await options.body.get("file").arrayBuffer()); assert.deepEqual(uploaded, bytes);
      return respond({ md5: createHash("md5").update(bytes).digest("hex") });
    }
    assert.equal(target.searchParams.get("method"), "create");
    return respond({ errno: 0, fs_id: 123456789 });
  } });
  const stored = await backend.uploadBytes(bytes, font, "provider-access");
  assert.equal(stored.fsID, "123456789");
  assert.deepEqual(steps, ["precreate", "upload", "create"]);
});

test("upload rejects duplicates before requesting provider credentials", async () => {
  const response = await handleUpload(request(input), config, { fetch: async url => {
    const result = authorized(url); if (result) return result;
    assert(new URL(url).pathname.endsWith("/font_library")); return respond([{ id: "existing" }]);
  } });
  assert.equal(response.status, 409);
});

test("successful upload publishes metadata and actor through one database transaction", async () => {
  const font = await prepareFont(input), cryptoBackend = new NetdiskBackend(config);
  const encrypted = await cryptoBackend.encrypt({ accessToken: "provider-access", refreshToken: "provider-refresh", expiresAt: Date.now() + 3600000 });
  let published = false;
  const fetch = async (url, options) => {
    const result = authorized(url); if (result) return result;
    const target = new URL(url), method = target.searchParams.get("method");
    if (target.pathname.endsWith("/font_library")) return respond([]);
    if (target.pathname.endsWith("/baidu_connections")) return respond([{ encrypted_tokens: encrypted }]);
    if (method === "precreate") return respond({ errno: 0, return_type: 1, uploadid: "test-upload", block_list: [0] });
    if (method === "upload") return respond({ md5: createHash("md5").update(bytes).digest("hex") });
    if (method === "create") return respond({ errno: 0, fs_id: 123 });
    assert(target.pathname.endsWith("/publish_baidu_font"));
    const body = JSON.parse(options.body); assert.equal(body.p_user, userID); assert.equal(body.p_font.id, font.id); assert.equal(body.p_storage.fs_id, "123");
    published = true; return respond({ schemaVersion: 1, fonts: [font] });
  };
  const response = await handleUpload(request(input), config, { fetch });
  assert.equal(response.status, 200); assert(published);
  const body = await response.json(); assert(body.auditRecorded);
  assert(!JSON.stringify(body).includes("provider-access"));
});

test("download streams only published files and never exposes netdisk credentials", async () => {
  const backend = new NetdiskBackend(config), font = await prepareFont(input);
  const encrypted = await backend.encrypt({ accessToken: "provider-access", refreshToken: "provider-refresh", expiresAt: Date.now() + 3600000 });
  backend.fetch = async (url, options) => {
    const target = new URL(url);
    if (target.pathname.endsWith("/font_files")) return respond([{ fs_id: "123", font_library: { size: bytes.length, file_name: "Test.ttf" } }]);
    if (target.pathname.endsWith("/baidu_connections")) return respond([{ encrypted_tokens: encrypted }]);
    if (target.searchParams.get("method") === "filemetas") return respond({ errno: 0, list: [{ dlink: "https://d.pcs.baidu.com/file/test" }] });
    assert.equal(target.hostname, "d.pcs.baidu.com");
    assert.equal(options.headers["User-Agent"], "pan.baidu.com");
    assert.equal(target.searchParams.get("access_token"), "provider-access");
    return new Response(bytes, { headers: { "Content-Length": String(bytes.length) } });
  };
  const response = await backend.stream(font.id);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
  assert(!Array.from(response.headers.entries()).flat().join(" ").includes("provider-access"));
  assert.equal(response.headers.get("Location"), null);
});

test("unpublished files and external download redirects are rejected", async () => {
  const backend = new NetdiskBackend(config, { fetch: async () => respond([]) });
  await assert.rejects(backend.stream("a".repeat(64)));
  const encrypted = await backend.encrypt({ accessToken: "provider-access", refreshToken: "provider-refresh", expiresAt: Date.now() + 3600000 });
  backend.fetch = async url => {
    const target = new URL(url);
    if (target.pathname.endsWith("/font_files")) return respond([{ fs_id: "123", font_library: { size: 44 } }]);
    if (target.pathname.endsWith("/baidu_connections")) return respond([{ encrypted_tokens: encrypted }]);
    assert.equal(target.searchParams.get("method"), "filemetas");
    return respond({ errno: 0, list: [{ dlink: "https://unexpected.example/private" }] });
  };
  await assert.rejects(backend.stream("a".repeat(64)));
});
