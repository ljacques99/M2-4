const http = require("node:http");
const assert = require("node:assert");

const PORT = 8081;
process.env.PORT = PORT;

const { execSync } = require("node:child_process");

const child = require("node:child_process").spawn("node", ["server.js"], {
  env: { ...process.env },
  stdio: "inherit",
});

setTimeout(() => {
  http.get(`http://127.0.0.1:${PORT}/healthz`, (res) => {
    assert.strictEqual(res.statusCode, 200);
    console.log("OK: /healthz devuelve 200");
    child.kill();
    process.exit(0);
  }).on("error", (err) => {
    console.error("FAIL:", err.message);
    child.kill();
    process.exit(1);
  });
}, 500);
