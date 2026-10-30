# EXPERIMENTS — ClearSwap

Hai thí nghiệm: (1) chi phí gas của các thao tác chính, (2) tấn công sandwich vào `settleWithETH` với các mức trần trượt giá khác nhau.

> **Trạng thái:** các bảng sandwich dưới đây được tính bằng một mô hình tham chiếu số nguyên. Mô hình mô phỏng đúng phép toán của `Exchange`/`Ledger` (cùng phí 3%, cùng thứ tự làm tròn, cùng cách định dạng 6 chữ số thập phân), nên kỳ vọng `forge test` ghi ra **đúng các số này** trong `out-experiments/sandwich.csv`. Hãy chạy lại các lệnh bên dưới để xác nhận và cập nhật file này nếu có khác biệt. Số liệu gas chỉ có sau khi chạy `forge`.

## Cách chạy

```bash
# 1) Gas: bảng gas theo hàm của Token / Exchange / Ledger
forge test --gas-report --match-path test/experiments/GasScenarios.t.sol > docs/gas-report.txt
#    gas đo bằng gasleft() cho từng kịch bản (log)
forge test -vv --match-path test/experiments/GasScenarios.t.sol

# 2) Sandwich: ghi out-experiments/sandwich.csv
forge test --match-path test/experiments/SandwichSweep.t.sol
head -n 25 out-experiments/sandwich.csv
```

## 1. Gas

`test/experiments/GasScenarios.t.sol`, pool 5,000 ETH / 5,000 CSU. Mỗi kịch bản là một test riêng:

| Kịch bản | Test | Ghi chú |
|---|---|---|
| `add_IOU`, không chu trình | `test_GasAddIOUNoCycle` | ghi một slot nợ mới |
| `add_IOU`, chu trình 3 nút | `test_GasAddIOUThreeNodeCycle` | kiểm path (3 nút) + cập nhật 3 cạnh |
| `settleWithTokens` | `test_GasSettleWithTokens` | 1 `transferFrom` |
| `settleWithETH` (trần 5%) | `test_GasSettleWithETH` | quote + swap + 2 transfer + hoàn ETH |
| `swapETHForTokens` / `swapTokensForETH` | `test_GasSwapETHForTokens`, `test_GasSwapTokensForETH` | |
| `addLiquidity` (lần đầu) | `test_GasAddLiquidity` | |
| `removeLiquidity` (có trả phí) | `test_GasRemoveLiquidity` | |
| `removeAllLiquidity` | `test_GasRemoveAllLiquidity` | |

Kết quả: xem `docs/gas-report.txt` (sinh bởi lệnh ở trên). Bảng trong file đó gộp mọi lời gọi của cùng một hàm, nên `min`/`max` của `add_IOU` tương ứng trường hợp không và có chu trình. Số đo riêng từng kịch bản nằm trong log của lệnh `-vv`.

## 2. Sandwich

`test/experiments/SandwichSweep.t.sol`. Mỗi ô (s, F) chạy trên một bản deploy mới:

1. Pool 5,000 ETH / 5,000 CSU; Alice nợ Bob 300 CSU (≈ 6% lượng token trong pool).
2. Alice ký `settleWithETH(Bob, 300)` với `value = quote × (100 + s) / 100`, trong đó `quote = 329.019522 ETH` là báo giá trung thực trước tấn công.
3. Sam front-run: `swapETHForTokens{value: F}`.
4. Giao dịch của Alice chạy: thành công nếu báo giá mới ≤ trần, ngược lại revert `"over cap"`.
5. Sam back-run: bán toàn bộ token vừa mua (vẫn chạy cả khi Alice revert).

Cột `alice_eth_paid` là ETH Alice thực trả (0 nếu revert); `sam_profit_eth = ETH thu về − F`.

### Kết quả (kỳ vọng, từ mô hình tham chiếu)

| s (%) | F = 50 | F = 100 | F = 200 | F = 500 |
|---|---|---|---|---|
| 0 | revert, Sam −2.941437 | revert, −5.856251 | revert, −11.608903 | revert, −28.298723 |
| 1 | revert, −2.941437 | revert, −5.856251 | revert, −11.608903 | revert, −28.298723 |
| 2 | revert, −2.941437 | revert, −5.856251 | revert, −11.608903 | revert, −28.298723 |
| 5 | Alice trả 335.641269, Sam **+3.291742** | 342.333219, **+6.681653** | revert, −11.608903 | revert, −28.298723 |
| 10 | 335.641269, **+3.291742** | 342.333219, **+6.681653** | 355.928246, **+13.753222** | revert, −28.298723 |
| 25 | 335.641269, **+3.291742** | 342.333219, **+6.681653** | 355.928246, **+13.753222** | 398.411816, **+37.257355** |

Báo giá sau front-run tăng lần lượt +2.01% (F = 50), +4.05% (F = 100), +8.18% (F = 200), +21.09% (F = 500) so với báo giá trung thực.

### Nhận xét

**(1) Trần s giới hạn F.** Alice chỉ bị "kẹp" khi cú front-run đẩy báo giá lên không quá `s%`. Với s ≤ 2%, mọi F trong thí nghiệm đều khiến giao dịch của Alice revert, nên Sam không thu được gì. Với s = 5% Sam chỉ dùng được F ≤ 100; với s = 10%, F ≤ 200; phải tới s = 25% thì F = 500 mới lọt. Thiệt hại của Alice luôn bị chặn bởi trần: trong trường hợp xấu nhất cô trả 398.41 ETH thay vì 329.02 ETH (+21.1% < 25%). Nhờ exact-out, Bob luôn nhận đúng 300 CSU.

**(2) Phí 3% hai chiều tạo chi phí đi-về ≈ 6%·F.** Khi trần chặn được Alice, sandwich chỉ còn là một vòng mua-bán, và Sam mất 5.66–5.88% của F (≈ 6%·F, không phụ thuộc s). Cũng vì chi phí này mà **sandwich nhỏ luôn lỗ**: tấn công chỉ có lãi khi lượng giá mà lệnh nạn nhân đẩy lên lớn hơn ~6%. `test_SandwichOnSmallDebtLoses` kiểm điều này với khoản nợ 50 CSU và trần 25% (Alice không revert). Mô hình cho lãi/lỗ của Sam khi *không có trần*:

| Nợ của Alice | F = 50 | F = 100 | F = 200 | F = 500 |
|---|---|---|---|---|
| 10 CSU (0.2% pool) | −5.50% | −5.47% | −5.42% | −5.26% |
| 50 CSU (1% pool) | −3.96% | −3.93% | −3.85% | −3.65% |
| 100 CSU (2% pool) | −1.98% | −1.93% | −1.84% | −1.57% |
| 300 CSU (6% pool) | +6.58% | +6.68% | +6.88% | +7.45% |

**Khuyến nghị:** với khoản nợ nhỏ (dưới ~2% thanh khoản pool), trần rộng cũng an toàn vì sandwich không có lãi. Với khoản nợ lớn nên đặt s nhỏ (1–2%), hoặc chia khoản trả thành nhiều lần nhỏ.
