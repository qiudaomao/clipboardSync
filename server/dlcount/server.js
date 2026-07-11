// Clipboard Sync download counter — zero-dependency Node HTTP service.
//
// Runs on the download mirror host behind nginx (see nginx.snippet.conf):
//   GET /dl/<file>        increments the file's counter and 302-redirects to
//                         /downloads/<file>, so every download through the
//                         landing page links is counted exactly once. Auto-
//                         updater traffic fetches /downloads/ directly and is
//                         deliberately NOT counted.
//   GET /api/dl/counts    returns {"total": n, "files": {...}} for the page.
//
// Counts persist to $STATE_DIRECTORY/counts.json (systemd DynamicUser +
// StateDirectory), written debounced via tmp-file rename.
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = 8790;
const STATE_DIR = process.env.STATE_DIRECTORY || "/var/lib/clipboardsync-dlcount";
const COUNTS_PATH = path.join(STATE_DIR, "counts.json");
const FILES = new Set([
  "clipboardSyncMac.zip",
  "clipboardSyncWin-Setup.exe",
  "clipboardSyncLinux-x86_64.flatpak",
  "clipboardSyncLinux-aarch64.flatpak",
  "clipboardSyncLinux.flatpak",
]);

let counts = {};
try {
  counts = JSON.parse(fs.readFileSync(COUNTS_PATH, "utf8"));
} catch {
  // First run or unreadable state: start from zero rather than failing.
}

let writeQueued = false;
function persist() {
  if (writeQueued) {
    return;
  }
  writeQueued = true;
  setTimeout(() => {
    writeQueued = false;
    const tmp = COUNTS_PATH + ".tmp";
    fs.writeFile(tmp, JSON.stringify(counts), (err) => {
      if (err) {
        console.error("persist failed:", err.message);
        return;
      }
      fs.rename(tmp, COUNTS_PATH, (renameErr) => {
        if (renameErr) {
          console.error("persist rename failed:", renameErr.message);
        }
      });
    });
  }, 250);
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/api/dl/counts") {
      const total = Object.values(counts).reduce((a, b) => a + b, 0);
      res.writeHead(200, {
        "content-type": "application/json",
        "cache-control": "no-store",
      });
      res.end(JSON.stringify({ total, files: counts }));
      return;
    }
    const match = url.pathname.match(/^\/dl\/([A-Za-z0-9._-]+)$/);
    if (match && FILES.has(match[1])) {
      counts[match[1]] = (counts[match[1]] || 0) + 1;
      persist();
      res.writeHead(302, {
        location: "/downloads/" + match[1],
        "cache-control": "no-store",
      });
      res.end();
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  })
  .listen(PORT, "127.0.0.1", () => {
    console.log(`dlcount listening on 127.0.0.1:${PORT}, state ${COUNTS_PATH}`);
  });
