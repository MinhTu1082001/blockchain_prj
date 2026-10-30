# CLAUDE.md — ClearSwap

Đặc tả đầy đủ: `CLEARSWAP_SPEC.md`. File này tóm tắt các quy ước bắt buộc (mục 2 của đặc tả). Làm theo từng phase; chỉ sang phase sau khi lệnh kiểm tra của phase trước chạy xanh.

## Toolchain
- Chỉ dùng Foundry (`forge`, `cast`, `anvil`). Không Hardhat, không Truffle.
- Solidity `0.8.28`, `evm_version = "cancun"` (để dùng biến `transient`).

## Thư viện
- Chỉ `forge-std` và `openzeppelin-contracts` v5.x, nằm trong `lib/` dưới dạng git submodule (`forge install`). Không dùng npm package nào cho contract.
- Remapping: `@openzeppelin/=lib/openzeppelin-contracts/`, `forge-std/=lib/forge-std/src/`.

## Client
- HTML + JavaScript thuần trong `web_app/`, ethers **v6** nạp từ `https://cdnjs.cloudflare.com/ajax/libs/ethers/6.13.4/ethers.umd.min.js`. Không bundler, không framework.

## An toàn
- Mọi hàm gửi ETH hoặc gọi token: thứ tự **checks → effects → interactions** và có guard `nonReentrant` dùng cờ `bool transient locked`.
- Không dùng `tx.origin` ở bất kỳ đâu.
- Mọi giả định là một `require` có thông điệp ngắn.

## Số học
- Không số thực. Nhân trước, chia sau.
- Lượng **người dùng trả cho pool** làm tròn **lên** (ceil); lượng **pool trả ra** làm tròn **xuống**. Bụi làm tròn luôn nghiêng về pool.

## Đơn vị
- ETH tính bằng wei; token 18 chữ số thập phân.
- Nợ trong Ledger là `uint32` đơn vị nguyên; khi quyết toán `want = uint256(amount) * UNIT`, `UNIT = 1e18`.
- Tỷ giá truyền vào hàm nhân `MULT = 1e5` ("đầu vào trên một đơn vị đầu ra × 1e5").

## Phong cách
- Mỗi contract ≤ ~250 dòng, NatSpec ngắn cho hàm public, giữ đúng tên hàm của đặc tả mục 4 (`add_IOU`, `disable_mint`, ...).
- Tên test: `test_<hành vi>`, `testRevert_<lý do>`, `testFuzz_<bất biến>`; invariant: `invariant_<mã>_<tên>`.
- Định dạng bằng `forge fmt` (mặc định của Foundry).

## Không làm
- Đa tài sản, oracle ngoài, lãi suất, token hóa nợ, UI cầu kỳ. Ghi ý tưởng vào `docs/FUTURE.md` thay vì code.

## Lệnh thường dùng
```bash
forge build
forge test -vv                                   # toàn bộ, gồm fuzz + invariant
forge test --match-path test/Exchange.t.sol      # một file
forge fmt --check
anvil                                            # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL0
python -m http.server 8000                       # mở http://localhost:8000/web_app/
```

## Bố cục
- `contracts/` — `Token.sol`, `Exchange.sol`, `Ledger.sol`
- `test/` — test đơn vị; `test/attacks/` — test tấn công; `test/invariants/` — handler + I1–I8; `test/experiments/` — gas & sandwich; `test/utils/Fixture.sol` — helper dùng chung
- `script/Deploy.s.sol` — deploy lên Anvil, ghi `deployments/anvil.json`
- `docs/DESIGN.md` (bất biến + quyết định thiết kế), `docs/EXPERIMENTS.md`, `docs/FUTURE.md`
