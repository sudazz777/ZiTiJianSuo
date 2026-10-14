import { handleUpload } from "./handler.mjs";
import { configuration } from "../_shared/netdisk.mjs";

Deno.serve((request: Request) => handleUpload(request, configuration(Deno.env)));
