import { NetdiskBackend, configuration, caught, json } from "../_shared/netdisk.mjs";
Deno.serve(async (request: Request) => {
  if (request.method !== "GET") return json({ error: "仅支持 GET 请求。" }, 405);
  try { return json(await new NetdiskBackend(configuration(Deno.env)).catalog()); }
  catch (error) { return caught(error); }
});
