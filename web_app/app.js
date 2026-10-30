"use strict";

// ClearSwap web client: plain JavaScript + ethers v6 (UMD build from cdnjs, global `ethers`).
// Serve the repository root (python -m http.server 8000) and open http://localhost:8000/web_app/.

const RPC_URL = "http://127.0.0.1:8545";
const DEPLOYMENT_URL = "../deployments/anvil.json";
const UNIT = 10n ** 18n;
const MULT = 100000n;
const FEE_NUM = 3n;
const FEE_DEN = 100n;
const MAX_PATH = 10;

const TOKEN_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 value) returns (bool)",
];

const EXCHANGE_ABI = [
  "function getPoolState() view returns (uint256 x, uint256 y, uint256 S)",
  "function ethFeeReserve() view returns (uint256)",
  "function tokenFeeReserve() view returns (uint256)",
  "function shares(address lp) view returns (uint256)",
  "function pendingFees(address lp) view returns (uint256 ethFee, uint256 tokenFee)",
  "function quoteTokensForETH(uint256 ethIn) view returns (uint256)",
  "function quoteETHForExactTokens(uint256 tokensOut) view returns (uint256 ethIn)",
  "function swapETHForTokens(uint256 maxRate) payable returns (uint256 tokensOut)",
  "function swapTokensForETH(uint256 amountTokens, uint256 maxRate) returns (uint256 ethOut)",
  "function addLiquidity(uint256 maxRate, uint256 minRate) payable",
  "function removeLiquidity(uint256 amountETH, uint256 maxRate, uint256 minRate)",
  "function removeAllLiquidity(uint256 maxRate, uint256 minRate)",
];

const LEDGER_ABI = [
  "function lookup(address debtor, address creditor) view returns (uint32)",
  "function add_IOU(address creditor, uint32 amount, address[] path)",
  "function settleWithTokens(address creditor, uint32 amount)",
  "function settleWithETH(address creditor, uint32 amount) payable",
  "event IOUAdded(address indexed debtor, address indexed creditor, uint32 amount, uint32 cancelled)",
  "event Settled(address indexed debtor, address indexed creditor, uint32 amount, bool viaETH, uint256 ethSpent)",
];

let provider;
let deployment;
let accounts = []; // Anvil accounts: only used to choose the signer, never as the ledger's user list
let signer;
let token;
let exchange;
let ledger;

// ------------------------------------------------------------------ helpers

const $ = (id) => document.getElementById(id);
const sameAddress = (a, b) => a.toLowerCase() === b.toLowerCase();
const ceilDiv = (a, b) => (a === 0n ? 0n : (a - 1n) / b + 1n);

function slippageBps(pct) {
  const value = Number(pct);
  if (!Number.isFinite(value) || value < 0) throw new Error("Biên trượt giá phải là số không âm (%)");
  return BigInt(Math.round(value * 100));
}

// The on-chain bounds for a rate (input per output × MULT) given a tolerance in percent.
function rateBounds(rate, pct) {
  const bps = slippageBps(pct);
  return {
    maxRate: (rate * (10000n + bps)) / 10000n,
    minRate: bps >= 10000n ? 0n : (rate * (10000n - bps)) / 10000n,
  };
}

// Debts are whole units stored as uint32.
function debtUnits(amount) {
  const n = Number(amount);
  if (!Number.isInteger(n) || n <= 0 || n > 4294967295) throw new Error("Số CSU phải là số nguyên dương (uint32)");
  return n;
}

function shortAddress(addr) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function label(addr) {
  const i = accounts.findIndex((a) => sameAddress(a, addr));
  return i >= 0 ? `#${i} ${shortAddress(addr)}` : shortAddress(addr);
}

// Accepts "#n" for Anvil account n, or a full address.
function resolveAddress(input) {
  const text = String(input).trim();
  const match = /^#(\d+)$/.exec(text);
  if (match) {
    const addr = accounts[Number(match[1])];
    if (!addr) throw new Error(`Không có tài khoản ${text}`);
    return addr;
  }
  return ethers.getAddress(text);
}

function fmt(wei, digits = 4) {
  return Number(ethers.formatEther(wei)).toLocaleString("en-US", { maximumFractionDigits: digits });
}

function log(message, isError = false) {
  const line = document.createElement("div");
  line.className = isError ? "err" : "ok";
  line.textContent = `[${new Date().toLocaleTimeString("vi-VN")}] ${message}`;
  $("log").prepend(line);
}

function errorMessage(e) {
  return e?.shortMessage || e?.reason || e?.info?.error?.message || e?.message || String(e);
}

async function sendTx(what, txPromise) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  log(`${what}: thành công (block ${receipt.blockNumber}, gas ${receipt.gasUsed})`);
  return receipt;
}

async function ensureAllowance(spender, amount) {
  const owner = await signer.getAddress();
  if ((await token.allowance(owner, spender)) < amount) {
    await sendTx("approve", token.connect(signer).approve(spender, amount));
  }
}

function tableRow(cells, numericFrom = Infinity) {
  const tr = document.createElement("tr");
  cells.forEach((text, i) => {
    const td = document.createElement("td");
    td.textContent = text;
    if (i >= numericFrom) td.className = "num";
    tr.append(td);
  });
  return tr;
}

// ------------------------------------------------------------------ ledger reads

async function ledgerEvents() {
  const from = Number(deployment.deployBlock ?? 0);
  const [added, settled] = await Promise.all([
    ledger.queryFilter(ledger.filters.IOUAdded(), from, "latest"),
    ledger.queryFilter(ledger.filters.Settled(), from, "latest"),
  ]);
  return [...added, ...settled];
}

// Everyone who ever appeared in an IOUAdded or Settled event.
async function getUsers() {
  const users = new Map();
  for (const ev of await ledgerEvents()) {
    for (const addr of [ev.args.debtor, ev.args.creditor]) {
      users.set(addr.toLowerCase(), ethers.getAddress(addr));
    }
  }
  return [...users.values()];
}

// Total units `user` owes to everybody else (`users` may be passed to avoid re-reading the events).
async function getTotalOwed(user, users) {
  const others = (users ?? (await getUsers())).filter((u) => !sameAddress(u, user));
  const debts = await Promise.all(others.map((u) => ledger.lookup(user, u)));
  return debts.reduce((sum, d) => sum + BigInt(d), 0n);
}

// Timestamp (seconds) of the last block in which `user` took part in a ledger event, or null.
async function getLastActive(user) {
  let last = -1;
  for (const ev of await ledgerEvents()) {
    if (sameAddress(ev.args.debtor, user) || sameAddress(ev.args.creditor, user)) {
      last = Math.max(last, ev.blockNumber);
    }
  }
  if (last < 0) return null;
  const block = await provider.getBlock(last);
  return block.timestamp;
}

// Prover side of cycle cancellation: shortest path from -> ... -> to along positive debts
// (BFS over the graph read with lookup). Returns null when no path of at most MAX_PATH nodes exists.
async function findPath(from, to) {
  const nodes = await getUsers();
  for (const a of [from, to]) {
    if (!nodes.some((n) => sameAddress(n, a))) nodes.push(a);
  }
  const pairs = nodes.flatMap((u) => nodes.filter((v) => !sameAddress(u, v)).map((v) => [u, v]));
  const amounts = await Promise.all(pairs.map(([u, v]) => ledger.lookup(u, v)));
  const next = new Map(nodes.map((n) => [n.toLowerCase(), []]));
  pairs.forEach(([u, v], i) => {
    if (BigInt(amounts[i]) > 0n) next.get(u.toLowerCase()).push(v);
  });

  const queue = [[from]];
  const visited = new Set([from.toLowerCase()]);
  while (queue.length > 0) {
    const path = queue.shift();
    const last = path[path.length - 1];
    if (sameAddress(last, to)) return path;
    if (path.length === MAX_PATH) continue;
    for (const v of next.get(last.toLowerCase())) {
      if (visited.has(v.toLowerCase())) continue;
      visited.add(v.toLowerCase());
      queue.push([...path, v]);
    }
  }
  return null;
}

// ------------------------------------------------------------------ ledger actions

async function add_IOU(creditor, amount) {
  const me = await signer.getAddress();
  const to = resolveAddress(creditor);
  const units = debtUnits(amount);
  if (sameAddress(to, me)) throw new Error("Không thể ghi nợ cho chính mình");
  const path = (await findPath(to, me)) ?? [];
  if (path.length >= 2) {
    log(`Chu trình: ${[me, ...path].map(label).join(" → ")} — gửi path để khử nợ vòng`);
  }
  await sendTx(`add_IOU(${label(to)}, ${units})`, ledger.connect(signer).add_IOU(to, units, path));
}

async function settleWithTokens(creditor, amount) {
  const to = resolveAddress(creditor);
  const units = debtUnits(amount);
  await ensureAllowance(deployment.ledger, BigInt(units) * UNIT);
  await sendTx(`settleWithTokens(${label(to)}, ${units})`, ledger.connect(signer).settleWithTokens(to, units));
}

async function settleWithETH(creditor, amount, maxSlippagePct) {
  const to = resolveAddress(creditor);
  const units = debtUnits(amount);
  const quote = await exchange.quoteETHForExactTokens(BigInt(units) * UNIT);
  const cap = (quote * (10000n + slippageBps(maxSlippagePct))) / 10000n;
  log(`Báo giá ${fmt(quote, 6)} ETH, gửi kèm trần ${fmt(cap, 6)} ETH`);
  const tx = ledger.connect(signer).settleWithETH(to, units, { value: cap });
  await sendTx(`settleWithETH(${label(to)}, ${units})`, tx);
}

// ------------------------------------------------------------------ exchange actions

async function poolRate() {
  const [x, y] = await exchange.getPoolState();
  return { x, y, rate: (x * MULT) / y };
}

async function addLiquidity(amountEth, maxSlippagePct) {
  const value = ethers.parseEther(String(amountEth));
  const { x, y, rate } = await poolRate();
  const { maxRate, minRate } = rateBounds(rate, maxSlippagePct);
  // tokens needed at the current rate, plus the tolerance in case the pool moves before execution
  const tokensNeeded = ceilDiv(y * value, x);
  await ensureAllowance(deployment.exchange, ceilDiv(tokensNeeded * (10000n + slippageBps(maxSlippagePct)), 10000n));
  const tx = exchange.connect(signer).addLiquidity(maxRate, minRate, { value });
  await sendTx(`addLiquidity(${amountEth} ETH + ~${fmt(tokensNeeded)} CSU)`, tx);
}

async function removeLiquidity(amountEth, maxSlippagePct) {
  const amount = ethers.parseEther(String(amountEth));
  const { rate } = await poolRate();
  const { maxRate, minRate } = rateBounds(rate, maxSlippagePct);
  const tx = exchange.connect(signer).removeLiquidity(amount, maxRate, minRate);
  await sendTx(`removeLiquidity(${amountEth} ETH)`, tx);
}

async function removeAllLiquidity(maxSlippagePct) {
  const { rate } = await poolRate();
  const { maxRate, minRate } = rateBounds(rate, maxSlippagePct);
  await sendTx("removeAllLiquidity", exchange.connect(signer).removeAllLiquidity(maxRate, minRate));
}

async function swapETHForTokens(amountEth, maxSlippagePct) {
  const value = ethers.parseEther(String(amountEth));
  const out = await exchange.quoteTokensForETH(value);
  if (out === 0n) throw new Error("Lượng ETH quá nhỏ");
  const { maxRate } = rateBounds((value * MULT) / out, maxSlippagePct);
  log(`Dự kiến nhận ${fmt(out, 6)} CSU`);
  await sendTx(`swapETHForTokens(${amountEth} ETH)`, exchange.connect(signer).swapETHForTokens(maxRate, { value }));
}

async function swapTokensForETH(amountToken, maxSlippagePct) {
  const amount = ethers.parseUnits(String(amountToken), 18);
  const [x, y] = await exchange.getPoolState();
  const net = amount - (amount * FEE_NUM) / FEE_DEN;
  const out = (x * net) / (y + net);
  if (out === 0n) throw new Error("Lượng CSU quá nhỏ");
  const { maxRate } = rateBounds((amount * MULT) / out, maxSlippagePct);
  await ensureAllowance(deployment.exchange, amount);
  log(`Dự kiến nhận ${fmt(out, 6)} ETH`);
  await sendTx(`swapTokensForETH(${amountToken} CSU)`, exchange.connect(signer).swapTokensForETH(amount, maxRate));
}

// ------------------------------------------------------------------ rendering

async function refresh() {
  const me = await signer.getAddress();
  const [state, ethFees, tokenFees, myEth, myCsu, myShares, pending, ledgerEth, ledgerCsu] = await Promise.all([
    exchange.getPoolState(),
    exchange.ethFeeReserve(),
    exchange.tokenFeeReserve(),
    provider.getBalance(me),
    token.balanceOf(me),
    exchange.shares(me),
    exchange.pendingFees(me),
    provider.getBalance(deployment.ledger),
    token.balanceOf(deployment.ledger),
  ]);
  const [x, y, S] = state;

  $("me-eth").textContent = fmt(myEth);
  $("me-csu").textContent = fmt(myCsu);
  $("me-shares").textContent = `${myShares} / ${S}`;
  $("me-fees").textContent = `${fmt(pending[0], 6)} ETH + ${fmt(pending[1], 6)} CSU`;

  $("pool-x").textContent = `${fmt(x)} ETH`;
  $("pool-y").textContent = `${fmt(y)} CSU`;
  $("pool-s").textContent = S.toString();
  $("pool-rate").textContent = `${fmt((x * UNIT) / y, 6)} (rate × 1e5 = ${(x * MULT) / y})`;
  $("fee-eth").textContent = `${fmt(ethFees, 6)} ETH`;
  $("fee-csu").textContent = `${fmt(tokenFees, 6)} CSU`;
  $("ledger-balance").textContent = `${fmt(ledgerEth)} ETH, ${fmt(ledgerCsu)} CSU`;

  await renderLedger();
}

async function renderLedger() {
  const users = await getUsers();
  const pairs = users.flatMap((u) => users.filter((v) => !sameAddress(u, v)).map((v) => [u, v]));
  const amounts = await Promise.all(pairs.map(([u, v]) => ledger.lookup(u, v)));

  const debts = $("debts");
  debts.replaceChildren();
  pairs.forEach(([u, v], i) => {
    if (BigInt(amounts[i]) > 0n) debts.append(tableRow([label(u), label(v), amounts[i].toString()], 2));
  });
  if (debts.children.length === 0) debts.append(tableRow(["Chưa có khoản nợ nào", "", ""]));

  const rows = await Promise.all(
    users.map(async (u) => {
      const [owed, last] = await Promise.all([getTotalOwed(u, users), getLastActive(u)]);
      const when = last === null ? "—" : new Date(Number(last) * 1000).toLocaleString("vi-VN");
      return tableRow([label(u), owed.toString(), when], 1);
    }),
  );
  $("users").replaceChildren(...rows);

  const known = [...accounts];
  for (const u of users) {
    if (!known.some((a) => sameAddress(a, u))) known.push(u);
  }
  $("known-addresses").replaceChildren(
    ...known.map((addr) => {
      const option = document.createElement("option");
      option.value = addr;
      option.label = label(addr);
      return option;
    }),
  );
}

// ------------------------------------------------------------------ wiring

const FORMS = {
  "form-iou": (f) => add_IOU(f.creditor.value, f.amount.value),
  "form-settle-tokens": (f) => settleWithTokens(f.creditor.value, f.amount.value),
  "form-settle-eth": (f) => settleWithETH(f.creditor.value, f.amount.value, f.slippage.value),
  "form-swap-eth": (f) => swapETHForTokens(f.amount.value, f.slippage.value),
  "form-swap-token": (f) => swapTokensForETH(f.amount.value, f.slippage.value),
  "form-add-liquidity": (f) => addLiquidity(f.amount.value, f.slippage.value),
  "form-remove-liquidity": (f) => removeLiquidity(f.amount.value, f.slippage.value),
};

async function guarded(button, task) {
  button.disabled = true;
  try {
    await task();
    await refresh();
  } catch (e) {
    log(errorMessage(e), true);
  } finally {
    button.disabled = false;
  }
}

function wire() {
  for (const [id, run] of Object.entries(FORMS)) {
    const form = $(id);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      guarded(event.submitter ?? form.querySelector("button"), () => run(form));
    });
  }
  $("remove-all").addEventListener("click", (event) => {
    guarded(event.currentTarget, () => removeAllLiquidity($("form-remove-liquidity").slippage.value));
  });
  $("refresh").addEventListener("click", (event) => guarded(event.currentTarget, async () => {}));
  $("account").addEventListener("change", () => {
    selectAccount(Number($("account").value)).catch((e) => log(errorMessage(e), true));
  });
}

async function selectAccount(index) {
  signer = await provider.getSigner(accounts[index]);
  $("account").value = String(index);
  await refresh();
}

async function init() {
  try {
    const res = await fetch(DEPLOYMENT_URL, { cache: "no-store" });
    if (!res.ok) throw new Error(`Không đọc được ${DEPLOYMENT_URL} (HTTP ${res.status}). Đã chạy script Deploy chưa?`);
    deployment = await res.json();

    provider = new ethers.JsonRpcProvider(RPC_URL);
    const network = await provider.getNetwork();
    if (deployment.chainId !== undefined && BigInt(deployment.chainId) !== network.chainId) {
      log(`Cảnh báo: anvil.json ghi chainId ${deployment.chainId} nhưng node trả về ${network.chainId}`, true);
    }
    if ((await provider.getCode(deployment.ledger)) === "0x") {
      throw new Error("Không có hợp đồng tại địa chỉ Ledger. Anvil vừa khởi động lại? Hãy chạy lại script Deploy.");
    }

    token = new ethers.Contract(deployment.token, TOKEN_ABI, provider);
    exchange = new ethers.Contract(deployment.exchange, EXCHANGE_ABI, provider);
    ledger = new ethers.Contract(deployment.ledger, LEDGER_ABI, provider);

    accounts = (await provider.listAccounts()).map((s) => s.address);
    const select = $("account");
    accounts.forEach((addr, i) => select.append(new Option(`#${i} ${addr}`, String(i))));

    wire();
    await selectAccount(Math.min(1, accounts.length - 1));
    log(`Đã kết nối ${RPC_URL} — Ledger ${deployment.ledger}`);
    provider.on("block", () => refresh().catch((e) => log(errorMessage(e), true)));
  } catch (e) {
    log(errorMessage(e), true);
  }
}

window.addEventListener("DOMContentLoaded", init);
