const https = require("https");

const IMPL = "0xc71b7CfBAca81838Aba9836329a2CcF132060B3B";

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
