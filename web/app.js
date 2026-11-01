import { createPublicClient, createWalletClient, custom, http, parseEther, formatEther, parseAbi, maxUint256 } from "https://esm.sh/viem@2.21.0";
import { bscTestnet } from "https://esm.sh/viem@2.21.0/chains";

const A = {
  router: "0x35315f8Dd71e965467F4A9A1f49e43A5719702B3",
  pancake: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
  wbnb: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd",
  token: "0x1B5A855A4827402E1bC92F33F7f5221cD64b7C0f",
  routerBlock: 140012030n,
  staking: "0xbb2AC381DAcCD4B077811Ed5518ed55d98Eefa39",
  stakingSink: "0xE5e6039266520D60757FbCdc104Ef68c91994D70",
  dead: "0x000000000000000000000000000000000000dEaD",
};
const EXPLORER = "https://testnet.bscscan.com/tx/";
const SLIPPAGE_BPS = 100n; // 1%
const ZERO = "0x0000000000000000000000000000000000000000";

const routerAbi = parseAbi([
  "function quoteFee(uint256) view returns (uint256 fee, uint256 amountAfterFee)",
  "function swapExactBNBForTokens(uint256,address[],address,uint256) payable",
  "function swapExactTokensForBNB(uint256,uint256,address[],address,uint256)",
  "function referralBps() view returns (uint16)",
]);
const swappedEvent = parseAbi(["event Swapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 fee, address referrer)"])[0];
const pancakeAbi = parseAbi(["function getAmountsOut(uint256,address[]) view returns (uint256[])"]);
const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);
const stakingAbi = parseAbi([
  "function stake(uint256,uint8) returns (uint256)",
  "function claim()",
  "function totalPending(address) view returns (uint256)",
  "function totalWeight() view returns (uint256)",
  "function minStake() view returns (uint256)",
]);

const pub = createPublicClient({ chain: bscTestnet, transport: http("https://bsc-testnet-rpc.publicnode.com") });
let wallet, account;
let bnbToToken = true;
const $ = (id) => document.getElementById(id);
const fmt = (v, d = 4) => Number(formatEther(v)).toLocaleString("en-US", { maximumFractionDigits: d });
const ref = (() => { const r = new URLSearchParams(location.search).get("ref"); return /^0x[0-9a-fA-F]{40}$/.test(r || "") ? r : ZERO; })();

// tabs
document.querySelectorAll("nav button").forEach((b) => b.onclick = () => {
  document.querySelectorAll("nav button").forEach((x) => x.classList.toggle("on", x === b));
  $("swap").classList.toggle("hidden", b.dataset.tab !== "swap");
  $("stake").classList.toggle("hidden", b.dataset.tab !== "stake");
  $("board").classList.toggle("hidden", b.dataset.tab !== "board");
  if (b.dataset.tab === "board") loadBoard();
});

// wallet
async function connect() {
  if (!window.ethereum) return alert("Install a wallet like MetaMask or Binance Wallet.");
  const [addr] = await window.ethereum.request({ method: "eth_requestAccounts" });
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x61" }] });
  } catch (e) {
    if (e.code === 4902) await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{ chainId: "0x61", chainName: "BNB Smart Chain Testnet", nativeCurrency: { name: "tBNB", symbol: "tBNB", decimals: 18 }, rpcUrls: ["https://bsc-testnet-rpc.publicnode.com"], blockExplorerUrls: ["https://testnet.bscscan.com"] }] });
    else throw e;
  }
  account = addr;
  wallet = createWalletClient({ account, chain: bscTestnet, transport: custom(window.ethereum) });
  $("connect").textContent = addr.slice(0, 6) + "…" + addr.slice(-4);
  refresh();
  if (!$("board").classList.contains("hidden")) loadBoard();
}
$("connect").onclick = () => connect().catch((e) => status("swapStatus", e.shortMessage || e.message));
window.ethereum?.on?.("accountsChanged", () => connect());

async function balances() {
  if (!account) return {};
  const [bnb, tok, pend] = await Promise.all([
    pub.getBalance({ address: account }),
    pub.readContract({ address: A.token, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
    pub.readContract({ address: A.staking, abi: stakingAbi, functionName: "totalPending", args: [account] }),
  ]);
  return { bnb, tok, pend };
}

async function refresh() {
  const b = await balances();
  if (account) {
    $("balIn").textContent = "Balance " + fmt(bnbToToken ? b.bnb : b.tok);
    $("balOut").textContent = "Balance " + fmt(bnbToToken ? b.tok : b.bnb);
    $("balStake").textContent = "Balance " + fmt(b.tok);
    $("pending").textContent = fmt(b.pend, 6);
    $("claim").disabled = b.pend === 0n;
    $("stakeBtn").disabled = false; $("stakeBtn").textContent = "Stake";
  }
  quote();
}

// swap
let lastOut = 0n;
let qTimer;
$("amtIn").oninput = () => { clearTimeout(qTimer); qTimer = setTimeout(quote, 250); };
$("flip").onclick = () => {
  bnbToToken = !bnbToToken;
  $("tokIn").textContent = bnbToToken ? "tBNB" : "tCNDR";
  $("tokOut").textContent = bnbToToken ? "tCNDR" : "tBNB";
  refresh();
};
const path = () => (bnbToToken ? [A.wbnb, A.token] : [A.token, A.wbnb]);

async function quote() {
  const go = $("go");
  let amt;
  try { amt = parseEther($("amtIn").value || "0"); } catch { amt = 0n; }
  if (amt === 0n) { $("amtOut").value = ""; $("info").textContent = ""; go.disabled = !account; go.textContent = account ? "Enter an amount" : "Connect wallet"; if (!account) go.disabled = false; return; }
  try {
    const [fee, net] = await pub.readContract({ address: A.router, abi: routerAbi, functionName: "quoteFee", args: [amt] });
    const outs = await pub.readContract({ address: A.pancake, abi: pancakeAbi, functionName: "getAmountsOut", args: [net, path()] });
    lastOut = outs[outs.length - 1];
    $("amtOut").value = fmt(lastOut, 6);
    $("info").textContent = `Fee ${fmt(fee, 6)} ${bnbToToken ? "tBNB" : "tCNDR"} · 0.25% burned · min received ${fmt(lastOut * (10000n - SLIPPAGE_BPS) / 10000n, 6)}`;
    go.disabled = !account; go.textContent = account ? "Swap" : "Connect wallet";
    if (!account) go.disabled = false;
  } catch (e) { $("info").textContent = "No quote: " + (e.shortMessage || e.message); go.disabled = true; }
}

function status(id, msg, hash) {
  $(id).innerHTML = hash ? `${msg} <a href="${EXPLORER}${hash}" target="_blank" rel="noopener">view tx</a>` : msg;
}

async function send(id, label, req) {
  if ((await window.ethereum.request({ method: "eth_chainId" })) !== "0x61") {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x61" }] });
  }
  status(id, label + "… confirm in wallet");
  // Simulate + estimate on our own RPC so the wallet's RPC can't fail the estimate.
  const sim = { ...req, account };
  await pub.simulateContract(sim);
  const [gas, gasPrice] = await Promise.all([pub.estimateContractGas(sim), pub.getGasPrice()]);
  const hash = await wallet.writeContract({ ...req, gas: (gas * 13n) / 10n, gasPrice });
  status(id, label + " pending", hash);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(label + " failed");
  status(id, label + " done ✓", hash);
}

$("go").onclick = async () => {
  if (!account) return connect();
  const btn = $("go"); btn.disabled = true;
  try {
    const amt = parseEther($("amtIn").value);
    const min = lastOut * (10000n - SLIPPAGE_BPS) / 10000n;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    if (bnbToToken) {
      await send("swapStatus", "Swap", { address: A.router, abi: routerAbi, functionName: "swapExactBNBForTokens", args: [min, path(), ref, deadline], value: amt });
    } else {
      const al = await pub.readContract({ address: A.token, abi: erc20Abi, functionName: "allowance", args: [account, A.router] });
      if (al < amt) await send("swapStatus", "Approve", { address: A.token, abi: erc20Abi, functionName: "approve", args: [A.router, maxUint256] });
      await send("swapStatus", "Swap", { address: A.router, abi: routerAbi, functionName: "swapExactTokensForBNB", args: [amt, min, path(), ref, deadline] });
    }
    $("amtIn").value = "";
    refresh(); loadStats();
  } catch (e) { status("swapStatus", e.shortMessage || e.message); }
  btn.disabled = false;
};

// stake
$("stakeBtn").onclick = async () => {
  if (!account) return connect();
  try {
    const amt = parseEther($("amtStake").value || "0");
    const min = await pub.readContract({ address: A.staking, abi: stakingAbi, functionName: "minStake" });
    if (amt < min) return status("stakeStatus", `Minimum stake is ${fmt(min, 2)} tCNDR`);
    const tier = Number(document.querySelector("input[name=tier]:checked").value);
    const al = await pub.readContract({ address: A.token, abi: erc20Abi, functionName: "allowance", args: [account, A.staking] });
    if (al < amt) await send("stakeStatus", "Approve", { address: A.token, abi: erc20Abi, functionName: "approve", args: [A.staking, maxUint256] });
    await send("stakeStatus", "Stake", { address: A.staking, abi: stakingAbi, functionName: "stake", args: [amt, tier] });
    $("amtStake").value = ""; refresh(); loadStats();
  } catch (e) { status("stakeStatus", e.shortMessage || e.message); }
};
$("claim").onclick = async () => {
  try { await send("stakeStatus", "Claim", { address: A.staking, abi: stakingAbi, functionName: "claim" }); refresh(); }
  catch (e) { status("stakeStatus", e.shortMessage || e.message); }
};

// stats, loaded after first paint
async function loadStats() {
  try {
    const [burn, w, sink] = await Promise.all([
      pub.readContract({ address: A.token, abi: erc20Abi, functionName: "balanceOf", args: [A.dead] }),
      pub.readContract({ address: A.staking, abi: stakingAbi, functionName: "totalWeight" }),
      pub.getBalance({ address: A.stakingSink }),
    ]);
    $("sBurn").textContent = fmt(burn, 2) + " tCNDR";
    $("sStake").textContent = fmt(w, 0);
    $("sSink").textContent = fmt(sink, 5) + " tBNB";
  } catch { /* stats are optional */ }
}
(window.requestIdleCallback || setTimeout)(loadStats);

// leaderboard: built in the browser from the router's Swapped events (no backend).
// Logs are cached in localStorage and fetched in 50k-block chunks (public RPC limit).
const CHUNK = 49999n;
const CACHE = "cinder.swaps.v1";
async function swapLogs() {
  let c = { to: (A.routerBlock - 1n).toString(), logs: [] };
  try { c = JSON.parse(localStorage.getItem(CACHE)) || c; } catch {}
  const head = await pub.getBlockNumber();
  let from = BigInt(c.to) + 1n;
  while (from <= head) {
    const to = from + CHUNK > head ? head : from + CHUNK;
    const logs = await pub.getLogs({ address: A.router, event: swappedEvent, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const a = l.args;
      c.logs.push([a.user, a.tokenIn, a.amountIn.toString(), a.fee.toString(), a.referrer]);
    }
    c.to = to.toString();
    from = to + 1n;
  }
  try { localStorage.setItem(CACHE, JSON.stringify(c)); } catch {}
  return c.logs;
}

let boardBusy = false;
async function loadBoard() {
  if (boardBusy) return; boardBusy = true;
  try {
    const [logs, refBps] = await Promise.all([
      swapLogs(),
      pub.readContract({ address: A.router, abi: routerAbi, functionName: "referralBps" }),
    ]);
    // Value token-side swaps in tBNB at the current pool price (testnet has one pair).
    const one = parseEther("1");
    let tokPrice = 0n;
    try { tokPrice = (await pub.readContract({ address: A.pancake, abi: pancakeAbi, functionName: "getAmountsOut", args: [one, [A.token, A.wbnb]] }))[1]; } catch {}
    const inBnb = (tokenIn, v) => (tokenIn.toLowerCase() === ZERO ? v : (v * tokPrice) / one);
    const users = new Map(); const refEarned = new Map();
    for (const [user, tokenIn, amt, fee, referrer] of logs) {
      const u = user.toLowerCase();
      const r = users.get(u) || { addr: user, swaps: 0, vol: 0n, fee: 0n };
      r.swaps++; r.vol += inBnb(tokenIn, BigInt(amt)); r.fee += inBnb(tokenIn, BigInt(fee));
      users.set(u, r);
      if (referrer.toLowerCase() !== ZERO) {
        const k = referrer.toLowerCase();
        refEarned.set(k, (refEarned.get(k) || 0n) + inBnb(tokenIn, (BigInt(amt) * BigInt(refBps)) / 10000n));
      }
    }
    // 1 point per 0.00001 BNB of fees paid, so wash trading costs real fees.
    const pts = (fee) => Number(fee / 10000000000000n);
    const rows = [...users.values()].sort((a, b) => (b.fee > a.fee ? 1 : b.fee < a.fee ? -1 : 0));
    const me = account?.toLowerCase();
    const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
    $("lbBody").innerHTML = rows.length
      ? rows.slice(0, 20).map((r, i) => `<tr class="${r.addr.toLowerCase() === me ? "you" : ""}"><td>${i + 1}</td><td>${short(r.addr)}</td><td>${r.swaps}</td><td>${fmt(r.vol, 4)}</td><td>${pts(r.fee).toLocaleString("en-US")}</td></tr>`).join("")
      : `<tr><td colspan="5" class="muted">No swaps yet. Be the first.</td></tr>`;
    $("lbNote").textContent = `${logs.length} swaps · volume in tBNB · tCNDR valued at today's pool price`;
    if (me) {
      const mine = users.get(me); const rank = rows.findIndex((r) => r.addr.toLowerCase() === me);
      $("mVol").textContent = mine ? fmt(mine.vol, 4) + " tBNB" : "0";
      $("mPts").textContent = mine ? pts(mine.fee).toLocaleString("en-US") : "0";
      $("mRank").textContent = rank >= 0 ? "#" + (rank + 1) : "—";
      $("mRef").textContent = fmt(refEarned.get(me) || 0n, 6) + " tBNB";
      const link = location.origin + location.pathname + "?ref=" + account;
      $("refLink").value = link; $("copyRef").disabled = false;
    }
  } catch (e) { $("lbNote").textContent = "Couldn't load the board: " + (e.shortMessage || e.message); }
  boardBusy = false;
}
$("copyRef").onclick = async () => { try { await navigator.clipboard.writeText($("refLink").value); $("copyRef").textContent = "Copied"; setTimeout(() => ($("copyRef").textContent = "Copy"), 1500); } catch { $("refLink").select(); } };
quote();
