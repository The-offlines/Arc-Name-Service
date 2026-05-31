const https = require("https");
const IMPL = "0x06743e5f8D3cFF5e0f6c5cd8CA516B51Ab3E3B70";
const options = { hostname: "testnet.arcscan.app",
  path: `/api?module=contract&action=getsourcecode&address=${IMPL}`, method: "GET" };
const req = https.request(options, (res) => {
  let data = "";
  res.on("data", chunk => data += chunk);
  res.on("end", () => {
    const parsed = JSON.parse(data);
    console.log("Contract name:", parsed.result[0]?.ContractName);
    console.log("Compiler:", parsed.result[0]?.CompilerVersion);
  });
});
req.on("error", e => console.error("Error:", e));
req.end();
