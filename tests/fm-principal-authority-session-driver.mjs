#!/usr/bin/env node
// Test-only dependency injection for simulating interruption after the queued
// captain-task receipt. Production executables expose no matching runtime flag.

import { executeTrustedSessionCli } from "../bin/fm-principal-authority.mjs";

executeTrustedSessionCli(process.argv.slice(2), {
  afterCaptainTaskQueued() {
    return true;
  },
});
