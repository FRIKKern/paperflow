#!/usr/bin/env node
// Backwards-compat shim. The per-instance bridge was merged into
// paperflow-daemon (host-scoped, port 8767) in the daemon-consolidation
// Goal (paperflow-du4). This shim exec's the new binary and logs the
// migration. Slated for removal one release later.
const path = require("path");
const { spawn } = require("child_process");
console.error("claude-bridge.js: superseded by paperflow-daemon (Goal paperflow-du4) - exec'ing new daemon");
spawn(process.argv[0], [path.join(__dirname, "paperflow-daemon")], { stdio: "inherit" }).on("exit", c => process.exit(c || 0));
