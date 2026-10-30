# CLEARSWAP_SPEC.md — Đặc tả để Claude Code dựng dự án ClearSwap

> **Cách dùng.** Đặt file này ở thư mục gốc của repo trống (`clearswap/`). Mở Claude Code tại đó và gõ:
> `Đọc toàn bộ CLEARSWAP_SPEC.md. Tạo CLAUDE.md tóm tắt các quy ước ở mục 2. Sau đó thực hiện Phase 0 và Phase 1, dừng lại báo cáo kết quả `forge test` trước khi sang phase tiếp.`
> Làm từng phase một; mỗi phase có "Definition of done" — chỉ sang phase sau khi lệnh kiểm tra chạy xanh.

---

## 1. Dự án là gì

ClearSwap = **sổ nợ nhóm tự bù trừ chu trình** (Blockchain Splitwise, CS251 Project #3) + **sàn AMM x·y = k** (CS251 Project #4), nối với nhau bằng hàm **quyết toán nợ bằng ETH trong một giao dịch**: người nợ gửi ETH, hợp đồng sổ nợ gọi AMM đổi sang token đơn vị nợ rồi chuyển cho chủ nợ. Mục tiêu là một dự án báo cáo môn học có: mã chạy được trên Anvil, bộ test an ninh, và số liệu thí nghiệm (gas, sandwich, công bằng phí LP).

Ba hợp đồng:

| Hợp đồng | Vai trò |
|---|---|
| `Token.sol` | ERC-20 (OpenZeppelin) có `mint` / `disable_mint`, là đơn vị ghi nợ |
| `Exchange.sol` | AMM ETH ↔ Token, phí 3% trên đầu vào, LP shares, phí tích lũy per-swap, biên trượt giá |
| `Ledger.sol` | Sổ nợ `debts[debtor][creditor]`, khử chu trình theo path client gửi, `settleWithTokens`, `settleWithETH` |

---

## 2. Quy ước bắt buộc (đưa vào CLAUDE.md)

- **Toolchain:** Foundry (forge/cast/anvil). Không Hardhat, không Truffle. Solidity `0.8.28`, `evm_version = "cancun"` (để dùng `transient`).
- **Thư viện:** chỉ `forge-std` và `openzeppelin-contracts` v5.x (cài bằng `forge install`). Không npm package nào cho contract.
- **Client:** HTML + JavaScript thuần, ethers **v6** nạp từ cdnjs (`https://cdnjs.cloudflare.com/ajax/libs/ethers/6.13.4/ethers.umd.min.js`). Không bundler, không framework.
- **An toàn:** mọi hàm gửi ETH hoặc gọi token đều theo thứ tự **checks → effects → interactions** và có guard `nonReentrant` (cờ `bool transient locked`). **Không dùng `tx.origin`** ở bất kỳ đâu. Mọi giả định là một `require` có thông điệp ngắn.
- **Số học:** không số thực. Nhân trước, chia sau. Lượng tiền **người dùng phải trả cho pool** làm tròn **lên** (ceil); lượng pool trả ra làm tròn xuống. Bụi làm tròn luôn nghiêng về pool.
- **Đơn vị:** ETH tính bằng wei; token 18 chữ số thập phân; nợ trong Ledger là `uint32` đơn vị nguyên, quy đổi `want = uint256(amount) * UNIT` với `UNIT = 1e18` khi quyết toán. Tỷ giá truyền vào hàm nhân `MULT = 1e5`, nghĩa là "ETH trên một token × 1e5".
- **Phong cách:** mỗi contract ≤ ~250 dòng, NatSpec ngắn cho hàm public, tên hàm giữ đúng như mục 4 (để tương thích với đề gốc). Test đặt tên `test_<hành vi>` / `testRevert_<lý do>` / `testFuzz_<bất biến>`.
- **Không làm:** đa tài sản, oracle ngoài, lãi suất, token hóa nợ, UI cầu kỳ. Ghi ý tưởng vào `docs/FUTURE.md` thay vì code.

---

## 3. Cấu trúc repo

```
clearswap/
  foundry.toml
  remappings.txt
  CLAUDE.md
  README.md                      # chạy từ đầu trên máy sạch
  contracts/
    Token.sol
    Exchange.sol
    Ledger.sol
  test/
    Token.t.sol
    Exchange.t.sol
    Fees.t.sol                   # phí, accumulator, kịch bản công bằng LP
    Ledger.t.sol
    Settle.t.sol
    attacks/
      Reentrancy.t.sol
      FakePath.t.sol
      Drain.t.sol
    invariants/
      Invariants.t.sol
    experiments/
      SandwichSweep.t.sol        # ghi CSV
      GasScenarios.t.sol
  script/
    Deploy.s.sol                 # deploy + tạo pool + phát token; ghi deployments/anvil.json
  web_app/
    index.html
    app.js
    style.css
  deployments/
    anvil.json                   # sinh bởi Deploy.s.sol
  out-experiments/               # CSV thí nghiệm
  docs/
    DESIGN.md                    # bất biến + quyết định thiết kế (mục 5, 6)
    EXPERIMENTS.md               # cách chạy và kết quả
    FUTURE.md
```

`foundry.toml` tối thiểu:

```toml
[profile.default]
src = "contracts"
out = "out"
libs = ["lib"]
solc = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read-write", path = "./out-experiments" }, { access = "read-write", path = "./deployments" }]
gas_reports = ["Token", "Exchange", "Ledger"]

[fuzz]
runs = 512

[invariant]
runs = 64
depth = 32
```

`remappings.txt`:

```
@openzeppelin/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
```

---

## 4. Đặc tả hợp đồng

### 4.1 `Token.sol`

```solidity
contract Token is ERC20, Ownable {
    bool public mintable = true;
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}
    function mint(uint256 amount) external onlyOwner;     // require(mintable); _mint(msg.sender, amount)
    function disable_mint() external onlyOwner;           // mintable = false, vĩnh viễn
}
```

Tên/ký hiệu mặc định: `"ClearSwap Unit"`, `"CSU"`. `decimals()` giữ 18.

### 4.2 `Exchange.sol`

**State**

```solidity
IERC20 public immutable token;
uint256 public constant MULT = 1e5;
uint256 public constant FEE_NUM = 3; uint256 public constant FEE_DEN = 100;
uint256 public constant MIN_ETH = 1 ether; uint256 public constant MIN_TOKEN = 1e18;
uint256 public constant INITIAL_SHARES = 1e5;

uint256 public ethReserve;  uint256 public tokenReserve;  uint256 public k;
uint256 public totalShares;  mapping(address => uint256) public shares;
uint256 public ethFeeReserve;  uint256 public tokenFeeReserve;
uint256 public accEthPerShare;  uint256 public accTokenPerShare;      // × 1e18
mapping(address => uint256) public ethFeeDebt;  mapping(address => uint256) public tokenFeeDebt;
bool transient locked;   // modifier nonReentrant
address public owner;    // người tạo pool
```

**Hàm** (giữ đúng tên):

| Hàm | Ngữ nghĩa |
|---|---|
| `createPool(uint256 amountTokens) external payable` | Chỉ owner, chỉ một lần (`require(ethReserve == 0)`). Kéo token bằng `transferFrom`, đặt dự trữ = (`msg.value`, `amountTokens`), `k = x*y`, `totalShares = INITIAL_SHARES` (phần khởi tạo **không** gán cho ai — đúng đề Proj4). |
| `getPoolState() view returns (uint256 x, uint256 y, uint256 S)` | Dự trữ (không gồm phí) và tổng shares. |
| `quoteTokensForETH(uint256 ethIn) view returns (uint256)` | `net = ethIn - ethIn*3/100`; `tokensOut = y*net/(x+net)`. |
| `quoteETHForExactTokens(uint256 tokensOut) view returns (uint256 ethIn)` | `require(tokensOut < y - MIN_TOKEN)`; `ethNet = ceilDiv(x*tokensOut, y - tokensOut)`; `ethIn = ceilDiv(ethNet*100, 97)`. (Với cách làm tròn này, swap với `msg.value = ethIn` luôn trả ≥ `tokensOut` — chứng minh ngắn trong DESIGN.md.) |
| `swapETHForTokens(uint256 maxRate) external payable nonReentrant returns (uint256 tokensOut)` | `fee = msg.value*3/100; net = msg.value - fee; tokensOut = y*net/(x+net)`; `require(tokensOut > 0)`; `require(y - tokensOut >= MIN_TOKEN, "drain")`; trượt giá: `require(msg.value*MULT/tokensOut <= maxRate, "slippage")`; cập nhật `x += net; y -= tokensOut; ethFeeReserve += fee; accEthPerShare += fee*1e18/totalShares`; **k không đổi** (không gán lại); cuối cùng `token.transfer(msg.sender, tokensOut)`. |
| `swapTokensForETH(uint256 amountTokens, uint256 maxRate) external nonReentrant returns (uint256 ethOut)` | Đối xứng: kéo token bằng `transferFrom`, phí tính trên token, `ethOut = x*net/(y+net)`, `require(x - ethOut >= MIN_ETH)`, trượt giá `amountTokens*MULT/ethOut <= maxRate` (giá của ETH tính bằng token), cập nhật, gửi ETH bằng `call`. |
| `addLiquidity(uint256 maxRate, uint256 minRate) external payable nonReentrant` | `rate = x*MULT/y`; `require(minRate <= rate && rate <= maxRate)`; `tokensNeeded = ceilDiv(y*msg.value, x)`; **trả phí đang chờ** của msg.sender (xem accumulator); `newShares = totalShares*msg.value/x`; kéo token; `x += msg.value; y += tokensNeeded; totalShares += newShares; shares[msg.sender] += newShares; k = x*y`; đặt lại `feeDebt = shares*acc/1e18`. |
| `removeLiquidity(uint256 amountETH, uint256 maxRate, uint256 minRate) external nonReentrant` | Kiểm biên tỷ giá; `burn = totalShares*amountETH/x`; `require(shares[msg.sender] >= burn)`; `tokensOut = y*amountETH/x`; `require(x - amountETH >= MIN_ETH && y - tokensOut >= MIN_TOKEN)`; trả phí đang chờ; cập nhật state **trước** khi gửi; gửi ETH (`call`) và token. |
| `removeAllLiquidity(uint256 maxRate, uint256 minRate) external nonReentrant` | `amountETH = x*shares[msg.sender]/totalShares`, rồi như trên. |
| `pendingFees(address lp) view returns (uint256 ethFee, uint256 tokenFee)` | `shares*acc/1e18 - feeDebt` cho mỗi loại. |

**Accumulator phí (per-swap):**

```
mỗi swap có phí f (ETH hoặc token):  acc += f * 1e18 / totalShares
pending(a) = shares[a] * acc / 1e18 - feeDebt[a]
khi a thêm/rút thanh khoản: trả pending(a) từ quỹ phí; cập nhật shares[a]; feeDebt[a] = shares[a]*acc/1e18
```

Phí thuộc `INITIAL_SHARES` (không ai sở hữu) ở lại quỹ — chấp nhận được, ghi vào DESIGN.md.

### 4.3 `Ledger.sol`

```solidity
contract Ledger {
    IERC20 public immutable token;  IExchange public immutable exchange;
    uint256 public constant UNIT = 1e18;  uint256 public constant MAX_PATH = 10;
    mapping(address => mapping(address => uint32)) private debts;
    bool transient locked;

    event IOUAdded(address indexed debtor, address indexed creditor, uint32 amount, uint32 cancelled);
    event Settled(address indexed debtor, address indexed creditor, uint32 amount, bool viaETH, uint256 ethSpent);

    function lookup(address debtor, address creditor) external view returns (uint32);
    function add_IOU(address creditor, uint32 amount, address[] calldata path) external;
    function settleWithTokens(address creditor, uint32 amount) external;
    function settleWithETH(address creditor, uint32 amount) external payable;
}
```

**`add_IOU(creditor, amount, path)`**
1. `require(amount > 0); require(creditor != msg.sender)`.
2. `debts[msg.sender][creditor] += amount` (overflow uint32 tự revert).
3. Nếu `path.length >= 2`: `require(path.length <= MAX_PATH)`; `require(path[0] == creditor && path[path.length-1] == msg.sender)`; mọi node trong path **đôi một khác nhau**; với mọi `i`: `require(debts[path[i]][path[i+1]] > 0, "edge")`. `m = min(các cạnh path, debts[msg.sender][creditor])`. Trừ `m` khỏi mọi cạnh path **và** cạnh mới. `cancelled = m`.
4. Emit `IOUAdded`.
Người nợ **luôn** là `msg.sender`; không có tham số `debtor`.

**`settleWithTokens(creditor, amount)`**: `require(debts[msg.sender][creditor] >= amount)`; trừ nợ; `require(token.transferFrom(msg.sender, creditor, uint256(amount)*UNIT))`; emit.

**`settleWithETH(creditor, amount)`** — thứ tự cố định:

```solidity
function settleWithETH(address creditor, uint32 amount) external payable nonReentrant {
    require(amount > 0 && debts[msg.sender][creditor] >= amount, "no such debt");   // checks
    debts[msg.sender][creditor] -= amount;                                          // effects
    uint256 want = uint256(amount) * UNIT;
    uint256 ethIn = exchange.quoteETHForExactTokens(want);
    require(ethIn <= msg.value, "over cap");                                         // trần = chống sandwich
    uint256 got = exchange.swapETHForTokens{value: ethIn}(type(uint256).max);        // interactions
    require(got >= want, "short");
    require(token.transfer(creditor, want));
    if (got > want) require(token.transfer(msg.sender, got - want));
    if (msg.value > ethIn) { (bool ok,) = payable(msg.sender).call{value: msg.value - ethIn}(""); require(ok, "refund"); }
    emit Settled(msg.sender, creditor, amount, true, ethIn);
}
```

Ledger không có `receive()`/`fallback()` nhận ETH ngoài `settleWithETH` (Exchange trả token, không trả ETH, nên không cần).

---

## 5. Bất biến (viết test cho từng dòng)

| Mã | Bất biến | Cách kiểm |
|---|---|---|
| I1 | Sau `add_IOU` có path hợp lệ, ít nhất một cạnh trên chu trình về 0 | test đơn vị |
| I2 | Nợ chỉ giảm bằng khử chu trình hoặc quyết toán; mỗi lần quyết toán, chủ nợ nhận đúng `amount*UNIT` token | test + kiểm số dư |
| I3 | Qua chuỗi swap bất kỳ, `ethReserve*tokenReserve >= k` (sai số nghiêng về pool); `k` chỉ đổi tại add/remove | fuzz |
| I4 | Luôn `ethReserve >= 1 ether && tokenReserve >= 1e18` | fuzz + testRevert |
| I5 | `Σ shares[LP] + INITIAL_SHARES == totalShares`; swap không đổi shares | invariant |
| I6 | Sau mỗi giao dịch, `address(ledger).balance == 0` và `token.balanceOf(ledger) == 0` | invariant |
| I7 | `Σ pendingFees ≤ quỹ phí` | invariant |
| I8 | `address(exchange).balance == ethReserve + ethFeeReserve`; tương tự token | invariant |

---

## 6. Các phase — làm tuần tự

### Phase 0 · Scaffold
- `forge init --no-git --force .` (giữ file này), xóa mẫu Counter.
- `forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std` (không `--no-commit` nếu repo chưa có git thì khởi tạo git trước).
- Viết `foundry.toml`, `remappings.txt`, cây thư mục mục 3, `CLAUDE.md` (tóm tắt mục 2), `README.md` khung.
- **DoD:** `forge build` thành công với một contract rỗng.

### Phase 1 · Token
- Cài đặt `Token.sol`; test: mint bởi owner, mint bởi người khác revert, mint sau `disable_mint` revert, `disable_mint` chỉ owner.
- **DoD:** `forge test --match-path test/Token.t.sol` xanh.

### Phase 2 · Exchange lõi (chưa phí accumulator)
- `createPool`, `getPoolState`, hai hàm swap (có phí 3% vào quỹ, có `MIN_*`, có biên trượt giá), `addLiquidity`, `removeLiquidity`, `removeAllLiquidity` với shares. Tạm cho `accEthPerShare` cập nhật nhưng chưa trả pending.
- Test theo số liệu đề: pool 5,000 ETH / 5,000 token; bán 100 ETH với maxRate rộng nhận ≈ 95.15 token; mua đúng 300 token cần `quoteETHForExactTokens(300e18)` ≈ 329.02 ETH; pool 1,000/1,000 + góp 500/500 ⇒ góp nhận 5e4 shares = 1/3.
- testRevert: rút cạn dưới 1 ETH/1 token; trượt giá quá biên; createPool lần hai; add ngoài biên tỷ giá.
- **DoD:** `forge test --match-path test/Exchange.t.sol` xanh.

### Phase 3 · Phí, accumulator, báo giá
- Hoàn thiện accumulator và `pendingFees`; trả pending khi add/remove.
- `test/Fees.t.sol` kịch bản công bằng: LP₀ tạo pool; 10 swap sinh phí; Bob góp 50%; 10 swap nữa; Bob rút — Bob nhận ≈ 1/3 phí giai đoạn hai và **0** phí giai đoạn một (sai số ≤ 1 wei/đơn vị làm tròn).
- Test bổ đề làm tròn: với mọi `tokensOut` fuzz trong khoảng hợp lệ, `swapETHForTokens{value: quoteETHForExactTokens(t)}` trả `>= t`.
- **DoD:** `forge test --match-path "test/Fees.t.sol"` xanh; fuzz làm tròn xanh.

### Phase 4 · Ledger (bù trừ chu trình)
- Cài đặt `lookup`, `add_IOU`. Test: chu trình 3 người (A→B 100, B→C 100, C→A 60 với path [A, B, C] khi C ghi nợ A... chú ý: path đi từ creditor tới msg.sender theo chiều nợ: khi C nợ A, path = [A, B, C] vì A→B, B→C đang > 0) ⇒ sau đó A→B = 40, B→C = 40, C→A = 0; chu trình 2 người (A→B 50, rồi B nợ A 30 với path [A, B]) ⇒ A→B = 20, B→A = 0.
- `test/attacks/FakePath.t.sol`: path không bắt đầu bằng creditor; không kết thúc bằng msg.sender; có cạnh = 0; node lặp; dài > 10; amount = 0; creditor = chính mình — tất cả revert, nợ không đổi.
- **DoD:** `forge test --match-path "test/Ledger.t.sol" --match-path "test/attacks/FakePath.t.sol"` xanh.

### Phase 5 · Quyết toán
- `settleWithTokens`, `settleWithETH` đúng mục 4.3. Test: sau settle bằng ETH, chủ nợ +`amount*UNIT`, nợ giảm đúng, Ledger số dư 0 (I6), người nợ được hoàn ETH thừa; `msg.value` thấp hơn báo giá ⇒ revert "over cap" **và nợ không đổi**.
- `test/attacks/Reentrancy.t.sol`: contract `EvilDebtor` có `receive()` gọi lại `settleWithETH`; kỳ vọng lần gọi lại revert và Tx ngoài vẫn hoàn tất đúng (hoặc revert toàn bộ nếu thiết kế chọn vậy — ghi rõ trong DESIGN.md), không bao giờ trả hai lần. Thêm `EvilLP` gọi lại `removeLiquidity` trong `receive()`.
- `test/attacks/Drain.t.sol`: mọi đường rút pool xuống dưới 1/1 đều revert.
- **DoD:** toàn bộ `forge test` xanh.

### Phase 6 · Script deploy và web app
- `script/Deploy.s.sol`: deploy Token, Exchange(token), Ledger(token, exchange); mint 20,000 token; approve; `createPool{value: 5000 ether}(5000e18)`; chuyển 1,000 token cho mỗi tài khoản Anvil #1–#5; ghi `deployments/anvil.json` `{token, exchange, ledger, chainId}` bằng `vm.writeJson`.
- Lệnh: `anvil` (terminal 1); `forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil #0>` (terminal 2).
- `web_app/`: một trang, ethers v6 từ cdnjs, `JsonRpcProvider("http://127.0.0.1:8545")`, chọn tài khoản trong 10 tài khoản Anvil (`provider.listAccounts()` chỉ để chọn signer — **không** dùng làm danh sách user của sổ nợ). Đọc địa chỉ từ `deployments/anvil.json` (chạy `python3 -m http.server 8000` trong thư mục gốc rồi mở `http://localhost:8000/web_app/`). Ba panel: Pool (x, y, S, tỷ giá, phí tích lũy), Sổ nợ (bảng debtor→creditor từ `getUsers()` + `lookup`), Hành động.
- Hàm JS bắt buộc (đều `async`): `getUsers()` (từ event `IOUAdded`/`Settled` qua `queryFilter`), `getTotalOwed(user)`, `getLastActive(user)` (timestamp block, `null` nếu không có), `add_IOU(creditor, amount)` (tự BFS creditor → signer trên đồ thị lấy từ `lookup`, gửi path), `settleWithTokens`, `settleWithETH(creditor, amount, maxSlippagePct)` (cap = quote × (100+s)/100, gửi làm `value`), `addLiquidity(amountEth, maxSlippagePct)`, `removeLiquidity(amountEth, maxSlippagePct)`, `removeAllLiquidity(maxSlippagePct)`, `swapETHForTokens(amountEth, maxSlippagePct)`, `swapTokensForETH(amountToken, maxSlippagePct)`. Mọi hàm kéo token phải `approve` trước.
- **DoD:** kịch bản tay trên UI: A nợ B 100, B nợ C 100, C nợ A 60 ⇒ bảng hiện A→B 40, B→C 40; A settle 40 cho B bằng ETH với 5% ⇒ B +40 CSU, Ledger số dư 0.

### Phase 7 · Thí nghiệm
- `test/experiments/GasScenarios.t.sol`: các kịch bản add_IOU (không/có chu trình 3 nút), settleWithTokens, settleWithETH, swap hai chiều, add/remove. Chạy `forge test --gas-report --match-path test/experiments/GasScenarios.t.sol > docs/gas-report.txt`.
- `test/experiments/SandwichSweep.t.sol`: pool 5,000/5,000; Alice `settleWithETH` 300 CSU với cap theo s ∈ {0,1,2,5,10,25}%; Sam front-run F ∈ {50,100,200,500} ETH rồi back-run bán hết token; ghi CSV `out-experiments/sandwich.csv` cột `s,F,alice_eth_paid,reverted,sam_profit_eth` bằng `vm.writeLine`. Dùng `vm.prank` cho từng vai; nếu Alice revert thì vẫn chạy back-run và ghi lãi (âm) của Sam.
- `docs/EXPERIMENTS.md`: cách chạy, bảng kết quả, hai nhận xét: (1) trần s giới hạn F; (2) phí 3% tạo chi phí vòng đi-về ≈ 6%·F nên sandwich nhỏ lỗ.
- **DoD:** hai file CSV/txt tồn tại và có số.

### Phase 8 · Invariant/fuzz và hoàn thiện
- `test/invariants/Invariants.t.sol` với handler ngẫu nhiên gọi swap/add/remove/add_IOU/settle; kiểm I3–I8.
- README: cài Foundry (macOS/WSL2), lệnh chạy test, deploy, mở UI, chạy thí nghiệm; `docs/DESIGN.md` gồm mục 5 và lý do 6 quyết định (đơn vị nợ một token; Ledger không giữ tiền; exact-out + trần ETH; prover/verifier cho chu trình; CEI + transient guard; accumulator).
- **DoD:** `forge test` (gồm invariant) xanh; `forge fmt --check` sạch; máy sạch làm theo README chạy được.

---

## 7. Kiểm tra chấp nhận cuối cùng

```bash
forge build && forge test -vv
forge test --gas-report --match-path test/experiments/GasScenarios.t.sol
forge test --match-path test/experiments/SandwichSweep.t.sol && head out-experiments/sandwich.csv
anvil &  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL0
python3 -m http.server 8000   # mở http://localhost:8000/web_app/ và chạy kịch bản A–B–C
```

Dự án đạt khi: mọi test xanh; 8 bất biến có test; 3 file attack test revert đúng chỗ; CSV sandwich có vùng revert khi s nhỏ; UI chạy kịch bản A–B–C; README đủ để người khác chạy lại.
