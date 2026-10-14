import { NetdiskBackend, requestBody, caught, fail, json } from "../_shared/netdisk.mjs";
import { prepareFont, unb64 } from "../_shared/font-validation.mjs";
export async function handleUpload(request, config, deps = {}) {
  if (request.method !== "POST") return json({ error: "仅支持 POST 请求。" }, 405);
  try {
    const backend = new NetdiskBackend(config, deps), user = await backend.authenticate(request, true);
    const input = await requestBody(request), font = await prepareFont(input, deps.crypto ?? crypto);
    const existing = await backend.database(`font_library?id=eq.${font.id}&select=id`);
    if (existing?.length) fail(409, "同一字体文件已经发布，无需重复上传。");
    const storage = await backend.uploadBytes(unb64(input.content), font, await backend.accessToken());
    const catalog = await backend.database("rpc/publish_baidu_font", "POST", { p_user: user.id, p_font: font, p_storage: { fs_id: storage.fsID, path: storage.path } });
    return json({ catalog, auditRecorded: true });
  } catch (error) { return caught(error); }
}
