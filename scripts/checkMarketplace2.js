const https = require("https");

const IMPL = "0x68B22d4691d18FDd010C10B674939eD2ADbb67dC";

const options = {
  hostname: "testnet.arcscan.app",
  path: `/api?module=contract&action=getsourcecode&address=${IMPL}`,
  method: "GET"
};

const req = https.request(options, (res) => {
  let data = "";
  res.on("data", chunk => data += chunk);
  res.on("end", () => {
    const parsed = JSON.parse(data);
    console.log("Status:", parsed.status);
    console.log("Contract name:", parsed.result[0]?.ContractName);
    console.log("Compiler:", parsed.result[0]?.CompilerVersion);
  });
});

req.on("error", e => console.error("Error:", e));
req.end();
