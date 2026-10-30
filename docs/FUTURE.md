# FUTURE — ý tưởng chưa làm

Theo quy ước của dự án, những ý tưởng dưới đây chỉ được ghi lại, **chưa** viết thành code.

- **Đa tài sản:** cho phép mỗi khoản nợ ghi bằng một token khác nhau, với pool cho từng cặp hoặc định tuyến qua nhiều pool.
- **Oracle giá ngoài (TWAP / Chainlink):** dùng làm trần trượt giá tham chiếu thay cho báo giá tức thời của chính pool.
- **Lãi suất / phí trễ hạn:** nợ tăng theo thời gian, cần thêm mốc thời gian cho từng cạnh.
- **Token hóa nợ:** biến mỗi cạnh nợ thành ERC-20/ERC-1155 có thể chuyển nhượng (bán khoản phải thu).
- **Chống MEV mạnh hơn:** commit-reveal cho `settleWithETH`, gửi qua mempool riêng, hoặc thêm hạn chót (`deadline`) cho mọi hàm swap/settle.
- **`permit` (EIP-2612):** gộp approve + settle/swap thành một giao dịch.
- **Bù trừ đa chu trình:** client tìm nhiều chu trình rời nhau rồi gửi một lô để khử trong một giao dịch.
- **Cache đồ thị nợ ở client:** dựng đồ thị từ sự kiện `IOUAdded`/`Settled` thay vì gọi `lookup` O(V²) lần.
- **Shares mịn hơn:** mint share theo căn bậc hai `sqrt(x·y)` như Uniswap v2 thay cho `INITIAL_SHARES = 1e5`, để thêm/rút lượng nhỏ không bị làm tròn mất một share.
- **Rút phí riêng:** hàm `claimFees()` cho LP nhận phí mà không phải thêm/rút thanh khoản.
