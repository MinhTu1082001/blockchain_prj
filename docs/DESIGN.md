# DESIGN — ClearSwap

ClearSwap gồm ba hợp đồng: một sổ nợ nhóm tự bù trừ chu trình (`Ledger`), một AMM `x·y = k` giữa ETH và token (`Exchange`), và token đơn vị nợ (`Token`, ký hiệu CSU). Ba phần nối với nhau qua `settleWithETH`: người nợ trả bằng ETH, Ledger đổi đúng lượng CSU cần thiết trên Exchange rồi chuyển cho chủ nợ, tất cả trong **một giao dịch**.

```
Người nợ ── settleWithETH{value: trần} ──▶ Ledger ── quoteETHForExactTokens(want) ──▶ Exchange
                                            │      ── swapETHForTokens{value: ethIn} ─▶ (CSU got)
                                            ├── want CSU ─────────────▶ Chủ nợ
                                            ├── got − want CSU ───────▶ Người nợ   (bụi làm tròn, thường 0–1 wei)
                                            └── msg.value − ethIn ETH ▶ Người nợ   (hoàn trần thừa)
```

## 1. Bất biến

| Mã | Bất biến | Nơi kiểm |
|---|---|---|
| I1 | Sau `add_IOU` có path hợp lệ, ít nhất một cạnh trên chu trình về 0 | `Ledger.t.sol` (`test_TwoNodeCycle`, `test_ThreeNodeCycle`, `test_CycleMinimumOnExistingEdge`, `testFuzz_CycleZeroesAnEdgeAndKeepsNetPositions`); `invariant_I1_CycleClearsAnEdge` |
| I2 | Nợ chỉ giảm bằng khử chu trình hoặc quyết toán; mỗi lần quyết toán chủ nợ nhận đúng `amount * UNIT` | `Settle.t.sol` (`test_SettleWithTokensPaysCreditor`, `test_SettleWithETHPaysExactTokensAndRefunds`, `testFuzz_SettleWithETHPaysExactly`); `invariant_I2_DebtsMatchHistory` (tổng nợ khớp lịch sử + cờ ghost) |
| I3 | Qua chuỗi swap bất kỳ `ethReserve * tokenReserve >= k`; `k` chỉ đổi tại add/remove | `Exchange.t.sol` (`testFuzz_SwapsKeepProductAboveK`); `invariant_I3_ProductNeverBelowK` |
| I4 | Luôn `ethReserve >= 1 ether` và `tokenReserve >= 1e18` | `attacks/Drain.t.sol` (mọi `testRevert_*`, `testFuzz_SwapsNeverBreakMinimums`); `invariant_I4_ReservesAboveMinimum` |
| I5 | `Σ shares[LP] + INITIAL_SHARES == totalShares`; swap không đổi shares | `invariant_I5_SharesAddUp`; `testFuzz_SwapsKeepProductAboveK`; cờ ghost trong `invariant_I3` |
| I6 | Sau mỗi giao dịch `address(ledger).balance == 0` và `token.balanceOf(ledger) == 0` | `_assertLedgerEmpty()` trong `Settle.t.sol`, `Reentrancy.t.sol`, `SandwichSweep.t.sol`; `invariant_I6_LedgerHoldsNothing` |
| I7 | `Σ pendingFees ≤ quỹ phí` (từng loại tài sản) | `Fees.t.sol` (`test_FeesSplitProRataBetweenLPs`); `invariant_I7_PendingFeesBacked` |
| I8 | `address(exchange).balance == ethReserve + ethFeeReserve`; tương tự với token | `_assertExchangeSolvent()` trong nhiều test; `invariant_I8_BalancesMatchBooks` |

Handler của bài invariant (`test/invariants/Invariants.t.sol`) gọi ngẫu nhiên swap hai chiều, add/remove/removeAll, `add_IOU` (có hoặc không có chu trình 2–3 nút), `settleWithTokens`, `settleWithETH` từ 5 tác nhân. Những gì không đọc được từ state (tổng nợ kỳ vọng, chủ nợ có nhận đúng không, swap có làm đổi `k` không) được ghi vào biến *ghost*.

### Vì sao I3 đúng
Swap ETH → token: `x' = x + net`, `y' = y − ⌊y·net/(x+net)⌋ ≥ y·x/(x+net)`, nên `x'·y' ≥ x·y ≥ k`. Chiều ngược lại đối xứng. Phí 3% nằm ngoài dự trữ nên không làm giảm tích; làm tròn xuống lượng trả ra làm tích chỉ có thể tăng. `addLiquidity`/`removeLiquidity` gán lại `k = x·y`.

### Vì sao I7 đúng
Mỗi swap có phí `f` cộng `⌊f·1e18/S⌋` vào accumulator, nên tổng quyền nhận của mọi LP có chủ không vượt `f·(S − INITIAL_SHARES)/S`. Phần của `INITIAL_SHARES` (không ai sở hữu) ở lại quỹ mãi mãi, làm đệm cho sai số làm tròn ≤ 1 wei/LP/lần cập nhật vị thế. Ngoài ra `_harvest` chặn số trả ở mức quỹ hiện có, nên một wei làm tròn không bao giờ làm quỹ âm.

## 2. Sáu quyết định thiết kế

1. **Đơn vị nợ là một token (CSU).** Nợ lưu dạng `uint32` đơn vị nguyên, quy đổi `amount * 1e18` khi trả. Lưu `uint32` khiến mapping nợ rẻ và tràn số tự revert (Solidity 0.8). Cả ba cách trả đều quy về cùng một tài sản: trả thẳng CSU, hoặc ETH đổi sang CSU. Nhờ vậy "chủ nợ nhận đúng `amount * UNIT`" (I2) là một mệnh đề kiểm được, không phụ thuộc tỷ giá.
2. **Ledger không giữ tiền (I6).** Ledger chỉ chuyển tiếp: token đi thẳng từ người nợ sang chủ nợ (`transferFrom`), còn ETH được tiêu hoặc hoàn ngay trong cùng giao dịch. Ledger không có `receive()`/`fallback()`, không có số dư để bị rút, và không cần quyền admin.
3. **Exact-out + trần ETH.** `settleWithETH` hỏi `quoteETHForExactTokens(want)` (hai lần làm tròn lên) rồi swap đúng `ethIn` đó, nên chủ nợ luôn nhận đủ, không thiếu một wei. `msg.value` đóng vai trò trần trượt giá do người nợ ký: nếu ai đó đẩy giá trước (front-run) làm báo giá vượt trần thì giao dịch revert `"over cap"` và nợ giữ nguyên. Chi phí tối đa của người nợ vì vậy bị chặn ở `s%`; xem thí nghiệm sandwich.
4. **Prover/verifier cho chu trình.** Tìm chu trình là việc tốn kém (BFS trên đồ thị), nên giao cho client (`findPath` trong `web_app/app.js`). Hợp đồng chỉ *kiểm* đường đi được gửi lên: tối đa `MAX_PATH = 10` nút, đúng hai đầu mút, các nút đôi một khác nhau (O(n²) ≤ 45 phép so sánh), và mọi cạnh > 0. Sau đó nó trừ cực tiểu `m` khỏi mọi cạnh, kể cả cạnh mới. Gas vì vậy bị chặn bởi hằng số, không phụ thuộc kích thước nhóm. Path giả thì revert (`test/attacks/FakePath.t.sol`). Trừ cùng `m` trên một chu trình giữ nguyên vị thế ròng của mọi thành viên, được kiểm bằng fuzz.
5. **CEI + transient guard.** Mọi hàm chuyển ETH/token cập nhật state xong rồi mới gọi ra ngoài, và có `nonReentrant` dùng `bool transient locked` (EIP-1153, chỉ tốn ~100 gas mỗi lần đọc/ghi, tự xóa cuối giao dịch). Guard được đặt lại `false` sau mỗi lời gọi để nhiều lời gọi hợp lệ trong cùng giao dịch vẫn chạy được (Ledger gọi `swapETHForTokens` của Exchange).
6. **Accumulator phí per-swap.** Mỗi swap cộng `fee·1e18/totalShares` vào `accEthPerShare`/`accTokenPerShare`. Mỗi LP lưu `feeDebt = shares·acc/1e18` tại lần đổi vị thế gần nhất; phần chờ nhận là `shares·acc/1e18 − feeDebt`. Chi phí O(1) cho mỗi swap và mỗi LP, không phải lặp qua danh sách LP. Người vào sau không nhận phí đã phát sinh trước khi họ vào (`Fees.t.sol`, `test_LateLPEarnsOnlyFeesAfterJoining`).

## 3. Làm tròn

| Đại lượng | Làm tròn | Ai có lợi |
|---|---|---|
| `tokensOut`, `ethOut` của swap | xuống | pool |
| phí `x·3/100` | xuống (phí nhỏ hơn), nhưng `net = x − fee` vì thế làm tròn lên | trung tính; dự trữ nhận nhiều hơn |
| `quoteETHForExactTokens`: `ethNet`, `ethIn` | lên (2 lần) | pool; người nợ trả dư ≤ vài wei và nhận lại bụi token |
| `tokensNeeded` khi add | lên | pool |
| `newShares` khi add | xuống | pool |
| `burn` khi remove | **lên** | pool |
| `tokensOut` khi remove | xuống | pool |
| `pendingFees`, accumulator | xuống | quỹ phí |

**Bổ đề (exact-out).** Với `0 < t < y − MIN_TOKEN`, swap với `msg.value = quoteETHForExactTokens(t)` trả về ít nhất `t` token.

*Chứng minh.* Đặt `e = ⌈x·t/(y−t)⌉` và `v = ⌈100·e/97⌉`.
- Từ `e ≥ x·t/(y−t)` suy ra `e·(y−t) ≥ x·t`, tức `y·e ≥ t·(x+e)`, nên `y·e/(x+e) ≥ t`.
- Từ `v ≥ 100·e/97` suy ra `97·v/100 ≥ e`.
- Trong swap: `fee = ⌊3v/100⌋`, nên `net = v − ⌊3v/100⌋ = ⌈97v/100⌉ ≥ 97v/100 ≥ e`.
- Hàm `n ↦ y·n/(x+n)` tăng, nên `y·net/(x+net) ≥ y·e/(x+e) ≥ t`. Vì `t` nguyên, `tokensOut = ⌊y·net/(x+net)⌋ ≥ t`. ∎

Bổ đề được fuzz trong `Fees.t.sol` (`testFuzz_ExactOutQuoteSuffices`) với dự trữ và `t` ngẫu nhiên. Nhờ bổ đề, `require(got >= want, "short")` trong `settleWithETH` không bao giờ kích hoạt khi trạng thái không đổi giữa báo giá và swap. Hai bước này nằm trong cùng một giao dịch nên trạng thái đúng là không đổi.

## 4. Quyết định bổ sung và chỗ khác với đặc tả

- **`burn` của `removeLiquidity` làm tròn lên** (`Math.ceilDiv(totalShares * amountETH, x)`), trong khi đặc tả viết phép chia thường. Nếu làm tròn xuống thì `amountETH < x / totalShares` cho `burn = 0`: ai cũng rút được ETH mà không đốt share nào, lặp lại vô hạn. Làm tròn lên khớp quy tắc "người dùng trả cho pool làm tròn lên"; xem `testRevert_DustWithdrawalWithoutShares` và `test_DustWithdrawalStillBurnsAShare`.
- **`removeAllLiquidity` đốt toàn bộ share** của người gọi, thay vì `ceil(S·amountETH/x)` (có thể nhỏ hơn 1 share), để không để lại share bụi. `amountETH = ⌊x·s/S⌋` không vượt phần thật của LP.
- **`_harvest` chặn khoản trả ở mức quỹ** (`Math.min`), để sai số làm tròn 1 wei không khóa được thao tác add/remove của LP.
- **`createPool` yêu cầu ≥ 1 ETH và ≥ 1e18 token** (để I4 đúng ngay từ đầu) và có `nonReentrant`, vì nó gọi token.
- **`addLiquidity` yêu cầu `newShares > 0`** (`"too small"`): góp ít hơn giá trị một share thì không được nhận gì nên bị chặn.
- **`add_IOU` từ chối chủ nợ `address(0)`**, gộp chung thông điệp với "chủ nợ là chính mình" (`"bad creditor"`). Path có độ dài < 2 bị bỏ qua (không khử), đúng như đặc tả.
- **Reentrancy khi hoàn tiền:** nếu người nợ là hợp đồng mà `receive()` của nó revert (ví dụ vì cố gọi lại `settleWithETH` và bị guard chặn rồi ném lỗi lên), thì `require(ok, "refund")` làm **revert toàn bộ** quyết toán: nợ giữ nguyên, chủ nợ không nhận gì. Nếu hợp đồng nuốt lỗi thì giao dịch ngoài hoàn tất bình thường, và lần gọi lại thất bại với `"reentrant"`. Cả hai biến thể đều được test trong `test/attacks/Reentrancy.t.sol`, và không bao giờ có chuyện trả hai lần. Exchange xử lý tương tự với `"eth send failed"`.
- **Phí thuộc `INITIAL_SHARES`** (không ai sở hữu) ở lại quỹ vĩnh viễn, đúng đề Proj4. Ví dụ trong `test_LateLPEarnsOnlyFeesAfterJoining`, toàn bộ phí giai đoạn 1 và 2/3 phí giai đoạn 2 nằm lại quỹ.
- **Exchange không có `receive()`**: ETH gửi trơn bị từ chối, nên I8 là đẳng thức. Riêng ETH bị ép vào bằng `selfdestruct` chỉ làm số dư *lớn hơn* sổ sách; trường hợp này nằm ngoài phạm vi test.

## 5. Hạn chế đã biết

- **Độ mịn của share:** `INITIAL_SHARES = 1e5`, nên trong pool 5,000 ETH một share đáng 0.05 ETH. Góp dưới mức đó bị từ chối, còn rút một lượng nhỏ vẫn đốt nguyên một share.
- **MEV trong phạm vi trần:** trần `s%` chặn thiệt hại của người nợ nhưng không loại bỏ sandwich. Nếu lệnh lớn (300 CSU ≈ 6% pool) và `s` rộng thì kẻ tấn công vẫn có lãi (xem `docs/EXPERIMENTS.md`).
- **Tìm chu trình ở client** đọc O(V²) lần `lookup`, phù hợp nhóm nhỏ. Client gửi path lỗi thời (nợ đã đổi) chỉ làm giao dịch revert, không gây hại.
- **`uint32`:** mỗi cạnh nợ tối đa ~4.29 tỷ đơn vị; vượt quá thì `add_IOU` revert.
