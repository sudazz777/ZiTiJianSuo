import { NetdiskBackend, requestBody, caught, fail, json } from "../_shared/netdisk.mjs";
export async function handleConnect(request, config, deps = {}) {
  if (request.method !== "POST") return json({ error: "仅支持 POST 请求。" }, 405);
  try {
    const backend = new NetdiskBackend(config, deps), user = await backend.authenticate(request, true);
    const input = await requestBody(request);
    if (!config.appKey || !config.secretKey) fail(503, "百度网盘开放平台应用尚未配置。");
    if (input.action === "start") {
      const state = backend.crypto.randomUUID();
      await backend.database("baidu_oauth_states", "POST", { state, user_id: user.id, expires_at: new Date(backend.now() + 10 * 60000).toISOString() });
      const url = new URL("https://openapi.baidu.com/oauth/2.0/authorize");
      for (const [key, value] of Object.entries({ response_type: "code", client_id: config.appKey, redirect_uri: "oob", scope: "basic,netdisk", state, confirm_login: "1" })) url.searchParams.set(key, value);
      return json({ authorizationURL: url.toString(), state });
    }
    if (input.action === "complete") {
      if (!/^[0-9a-f-]{36}$/i.test(input.state ?? "") || typeof input.code !== "string" || !input.code.trim() || input.code.length > 1024) fail(400, "授权码或授权状态无效，请重新开始授权。");
      const states = await backend.database(`baidu_oauth_states?state=eq.${input.state}&user_id=eq.${user.id}&expires_at=gt.${encodeURIComponent(new Date(backend.now()).toISOString())}`, "DELETE", undefined, "return=representation");
      if (!states?.length) fail(400, "授权已过期或已经使用，请重新开始授权。");
      const tokens = await backend.exchange({ grant_type: "authorization_code", code: input.code.trim(), redirect_uri: "oob" });
      await backend.saveTokens(tokens);
      return json({ connected: true });
    }
    fail(400, "未知授权操作。");
  } catch (error) { return caught(error); }
}
