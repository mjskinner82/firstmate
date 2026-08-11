#!/usr/bin/env node
// Test-only dependency injection for simulating interruption after the queued
// captain-task receipt. Production executables expose no matching runtime flag.

import { executeTrustedSessionCli } from "../bin/fm-principal-authority.mjs";
import { writeFileSync } from "node:fs";

executeTrustedSessionCli(process.argv.slice(2), {
  afterCaptainTaskQueued() {
    const holdMilliseconds = Number(process.env.FM_PRINCIPAL_TEST_HOLD_MS || 0);
    if (holdMilliseconds > 0) {
      writeFileSync(process.env.FM_PRINCIPAL_TEST_LOCK_READY, "ready\n");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, holdMilliseconds);
    }
    return true;
  },
});
