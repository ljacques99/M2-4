const http = require("node:http");

const PORT = process.env.PORT || 8080;
const ENV = process.env.ENV || "unknown";

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", env: ENV }));
    return;
  }

  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`oms-platform smoke app (${ENV})\n`);
});

server.listen(PORT, () => {
  console.log(`listening on :${PORT}`);
});
