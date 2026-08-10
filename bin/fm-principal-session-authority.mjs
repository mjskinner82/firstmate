#!/usr/bin/env node
// Local Firstmate trusted-session recorder for direct captain decisions.

import { executeTrustedSessionCli } from "./fm-principal-authority.mjs";

executeTrustedSessionCli(process.argv.slice(2));
