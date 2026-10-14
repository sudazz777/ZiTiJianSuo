import { handleConnect } from "./handler.mjs";
import { configuration } from "../_shared/netdisk.mjs";
Deno.serve((request: Request) => handleConnect(request, configuration(Deno.env)));
