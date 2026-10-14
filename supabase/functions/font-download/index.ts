import { NetdiskBackend, configuration, caught, fail, json } from "../_shared/netdisk.mjs";
Deno.serve(async (request: Request) => {
  if (request.method !== "GET") return json({ error: "仅支持 GET 请求。" }, 405);
  try {
    const id = new URL(request.url).searchParams.get("id");
    if (!/^[0-9a-f]{64}$/.test(id ?? "")) fail(400, "字体标识无效。");
    return await new NetdiskBackend(configuration(Deno.env)).stream(id);
  } catch (error) { return caught(error); }
});
