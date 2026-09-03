const http = require("http");

const PORT = process.env.PORT || 3000;

const page = `<!doctype html>
<html>
  <head><title>Node.js on Docker</title></head>
  <body style="font-family: system-ui; text-align: center; padding-top: 4rem">
    <h1>Hello World from Node.js!</h1>
    <p>Served by a Node.js container</p>
  </body>
</html>`;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(page);
});

server.listen(PORT, () => console.log(`node app listening on ${PORT}`));
