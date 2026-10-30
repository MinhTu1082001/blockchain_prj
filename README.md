# ClearSwap

**Sổ nợ nhóm tự bù trừ chu trình** (Blockchain Splitwise, CS251 Project #3) + **sàn AMM x·y = k** (CS251 Project #4), nối với nhau bằng **quyết toán nợ bằng ETH trong một giao dịch**: người nợ gửi ETH, hợp đồng sổ nợ đổi ETH sang token đơn vị nợ trên AMM rồi chuyển cho chủ nợ.

| Hợp đồng | Vai trò |
|---|---|
| `contracts/Token.sol` | ERC-20 "ClearSwap Unit" (CSU), có `mint` / `disable_mint`; là đơn vị ghi nợ |
| `contracts/Exchange.sol` | AMM ETH ↔ CSU: phí 3% trên đầu vào, LP shares, accumulator phí per-swap, biên trượt giá |
| `contracts/Ledger.sol` | Sổ nợ `debts[debtor][creditor]`, khử chu trình theo path client gửi, `settleWithTokens`, `settleWithETH` |

Thiết kế, bất biến và lý do các quyết định: [docs/DESIGN.md](docs/DESIGN.md). Thí nghiệm gas và sandwich: [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md).

## Cấu trúc thư mục

```
contracts/            Token.sol, Exchange.sol, Ledger.sol
test/                 Token, Exchange, Fees, Ledger, Settle (.t.sol)
test/attacks/         Reentrancy, FakePath, Drain
test/invariants/      Invariants.t.sol (handler + I1–I8)
test/experiments/     GasScenarios.t.sol, SandwichSweep.t.sol (ghi CSV)
test/utils/           Fixture.sol (helper deploy dùng chung)
script/Deploy.s.sol   deploy lên Anvil, ghi deployments/anvil.json
web_app/              index.html, app.js, style.css (ethers v6 từ cdnjs)
out-experiments/      CSV thí nghiệm
docs/                 DESIGN.md, EXPERIMENTS.md, FUTURE.md
lib/                  forge-std, openzeppelin-contracts v5.1.0 (git submodule)
```

## Chạy dự án

Chọn hướng dẫn theo máy của bạn:

- [macOS (MacBook Air)](#hướng-dẫn-chạy-trên-macos-macbook-air)
- [Windows 10/11](#hướng-dẫn-chạy-trên-windows)

Cả hai hướng dẫn đi qua cùng sáu bước: cài công cụ → lấy mã nguồn → build và test → chạy Anvil và deploy → mở web app → chạy thí nghiệm. Những gì giống nhau trên mọi máy nằm ở [Tham khảo chung](#tham-khảo-chung).

> Mã chưa được chạy thử thực tế trên cả hai hệ điều hành. Xem [Tương thích](#tương-thích-windows-và-macbook-air) để biết đã kiểm tra những gì.

## Hướng dẫn chạy trên macOS (MacBook Air)

**Cần có:** MacBook Air chip Apple M1–M4 hoặc Intel, kết nối Internet, khoảng 1 GB đĩa trống. Mọi lệnh gõ trong ứng dụng **Terminal** (⌘ Space → gõ "Terminal").

### Bước 1. Cài công cụ

```bash
xcode-select --install          # cài git và python3; báo "already installed" thì bỏ qua
curl -L https://foundry.paradigm.xyz | bash
grep -q '.foundry/bin' ~/.zshrc 2>/dev/null || echo 'export PATH="$PATH:$HOME/.foundry/bin"' >> ~/.zshrc
source ~/.zshrc
foundryup                       # tải forge, cast, anvil, chisel bản gốc cho Mac
forge --version
anvil --version
```

Dòng `grep … || echo …` thêm thư mục Foundry vào PATH. Chạy lại nhiều lần cũng không ghi trùng. Cần dòng này vì script cài hiện tại chỉ in hướng dẫn thêm PATH ra màn hình, không tự thêm.

<details>
<summary>Nếu <code>foundryup</code> lỗi: cài thủ công</summary>

```bash
mkdir -p ~/.foundry/bin
curl -L https://github.com/foundry-rs/foundry/releases/download/v1.8.5/foundry_v1.8.5_darwin_arm64.tar.gz | tar -xz -C ~/.foundry/bin
# MacBook Air chip Intel: thay darwin_arm64 bằng darwin_amd64
```

Nếu tải file bằng trình duyệt thay vì `curl`, Gatekeeper của macOS sẽ chặn chạy. Gỡ chặn bằng `xattr -dr com.apple.quarantine ~/.foundry/bin`.

</details>

### Bước 2. Lấy mã nguồn

```bash
mkdir -p ~/dev && cd ~/dev
git clone --recurse-submodules https://github.com/MinhTu1082001/blockchain_prj.git clearswap
cd clearswap
```

Nếu đã clone mà thiếu thư mục `lib/`: `git submodule update --init --recursive`.

### Bước 3. Build và chạy test

```bash
forge build                     # lần đầu tự tải solc 0.8.28
forge test -vv                  # toàn bộ test: đơn vị, tấn công, fuzz, invariant
forge fmt --check               # không in gì nghĩa là định dạng đã chuẩn
```

### Bước 4. Chạy Anvil và deploy

Cần hai tab Terminal. ⌘T mở tab mới; nếu tab mới không ở thư mục repo thì `cd ~/dev/clearswap`.

Tab 1 (để chạy suốt buổi):

```bash
anvil
```

Tab 2:

```bash
export ANVIL0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL0
cat deployments/anvil.json
```

`ANVIL0` là khóa riêng mặc định của tài khoản Anvil #0. Khóa này ai cũng biết, chỉ dùng cho mạng thử.

### Bước 5. Mở web app

Ở tab 2 (hoặc một tab mới), tại thư mục gốc repo:

```bash
python3 -m http.server 8000 --bind 127.0.0.1
```

Mở <http://127.0.0.1:8000/web_app/> trong Safari hoặc Chrome, hoặc gõ `open http://127.0.0.1:8000/web_app/` ở một tab khác. Sau đó chạy [kịch bản kiểm tra web app](#kịch-bản-kiểm-tra-web-app).

### Bước 6. Chạy thí nghiệm

Bước này không cần Anvil.

```bash
forge test --gas-report --match-path test/experiments/GasScenarios.t.sol > docs/gas-report.txt
forge test --match-path test/experiments/SandwichSweep.t.sol
head -n 25 out-experiments/sandwich.csv
shasum -a 256 out-experiments/sandwich.csv      # để so với máy khác
```

### Dừng và chạy lại

Nhấn Ctrl+C trong tab `anvil` và tab `http.server`. Mỗi lần chạy lại `anvil`, chuỗi bắt đầu lại từ đầu, nên phải làm lại bước 4.

### Sự cố thường gặp trên macOS

| Thông báo | Cách xử lý |
|---|---|
| `zsh: command not found: forge` | `source ~/.zshrc` hoặc mở tab mới; kiểm tra dòng PATH ở bước 1 |
| `xcrun: error: invalid active developer path` | chạy `xcode-select --install` |
| `dyld: Library not loaded … libusb` | `brew install libusb` (cần [Homebrew](https://brew.sh)) |
| "cannot be opened because the developer cannot be verified" | `xattr -dr com.apple.quarantine ~/.foundry/bin` |
| `Address already in use` ở cổng 8000 | đổi sang cổng khác, ví dụ `python3 -m http.server 8080 --bind 127.0.0.1`, rồi mở `http://127.0.0.1:8080/web_app/`. Cổng 8545 của Anvil phải giữ nguyên vì web app gọi đúng cổng này |

## Hướng dẫn chạy trên Windows

**Cần có:** Windows 10/11 64-bit, kết nối Internet, khoảng 1 GB đĩa trống. Hướng dẫn dùng **Git Bash** để các lệnh giống hệt bản macOS. Muốn dùng PowerShell thì xem [cuối mục này](#dùng-powershell-thay-cho-git-bash).

### Bước 1. Cài công cụ

1. Cài [Git for Windows](https://git-scm.com/download/win), giữ các tùy chọn mặc định (có kèm **Git Bash**).
2. Cài [Python 3](https://www.python.org/downloads/windows/), tick **"Add python.exe to PATH"** ở màn hình đầu tiên.
3. Mở **Git Bash** (Start → gõ "Git Bash") và chạy:

```bash
curl -L https://foundry.paradigm.xyz | bash
grep -q '.foundry/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$PATH:$HOME/.foundry/bin"' >> ~/.bashrc
source ~/.bashrc
foundryup                       # tải forge, cast, anvil, chisel bản Windows x64
forge --version
anvil --version
```

Dòng `grep … || echo …` có cùng tác dụng như trên macOS: thêm Foundry vào PATH, và không ghi trùng khi chạy lại. Lần mở Git Bash tiếp theo có thể in `WARNING: Found ~/.bashrc but no ~/.bash_profile…` rồi tự tạo `~/.bash_profile`. Đây là hành vi bình thường của Git for Windows.

<details>
<summary>Nếu <code>foundryup</code> lỗi: cài thủ công</summary>

1. Tải `foundry_v1.8.5_win32_amd64.zip` từ [GitHub Releases của foundry-rs](https://github.com/foundry-rs/foundry/releases).
2. Giải nén toàn bộ file `.exe` vào `C:\Users\<tên-bạn>\.foundry\bin`.
3. Mở PowerShell, chạy `Get-ChildItem $env:USERPROFILE\.foundry\bin | Unblock-File` để bỏ dấu "tải từ Internet" của Windows.
4. Quay lại Git Bash, chạy hai dòng `grep … || echo …` và `source ~/.bashrc` ở trên.

</details>

### Bước 2. Lấy mã nguồn

Đặt repo ở một đường dẫn ngắn và nằm ngoài OneDrive, ví dụ `C:\dev`:

```bash
mkdir -p /c/dev && cd /c/dev
git clone --recurse-submodules https://github.com/MinhTu1082001/blockchain_prj.git clearswap
cd clearswap
```

- Nếu git báo `unable to create file … Permission denied`: Windows Defender đang quét file. Chạy `git submodule update --init --recursive` để lấy lại phần thiếu.
- Nếu git báo `Filename too long`: chạy `git config --global core.longpaths true` rồi clone lại.

### Bước 3. Build và chạy test

```bash
forge build                     # lần đầu tự tải solc 0.8.28
forge test -vv                  # toàn bộ test: đơn vị, tấn công, fuzz, invariant
forge fmt --check               # không in gì nghĩa là định dạng đã chuẩn
```

### Bước 4. Chạy Anvil và deploy

Mở hai cửa sổ Git Bash, cả hai chạy `cd /c/dev/clearswap`.

Cửa sổ 1 (để chạy suốt buổi):

```bash
anvil
```

Cửa sổ 2:

```bash
export ANVIL0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL0
cat deployments/anvil.json
```

`ANVIL0` là khóa riêng mặc định của tài khoản Anvil #0. Khóa này ai cũng biết, chỉ dùng cho mạng thử.

### Bước 5. Mở web app

Ở cửa sổ 2 (hoặc một cửa sổ mới), tại thư mục gốc repo:

```bash
python -u -m http.server 8000 --bind 127.0.0.1     # -u để log hiện ngay trong Git Bash
```

Mở <http://127.0.0.1:8000/web_app/> trong Edge hoặc Chrome, hoặc gõ `start http://127.0.0.1:8000/web_app/` ở một cửa sổ Git Bash khác. Sau đó chạy [kịch bản kiểm tra web app](#kịch-bản-kiểm-tra-web-app).

### Bước 6. Chạy thí nghiệm

Bước này không cần Anvil. Nếu đang mở `sandwich.csv` bằng Excel thì đóng lại trước, vì Excel khóa file.

```bash
forge test --gas-report --match-path test/experiments/GasScenarios.t.sol > docs/gas-report.txt
forge test --match-path test/experiments/SandwichSweep.t.sol
head -n 25 out-experiments/sandwich.csv
sha256sum out-experiments/sandwich.csv          # để so với máy khác
```

### Dừng và chạy lại

Nhấn Ctrl+C trong cửa sổ `anvil` và cửa sổ `http.server`. Mỗi lần chạy lại `anvil`, chuỗi bắt đầu lại từ đầu, nên phải làm lại bước 4.

### Dùng PowerShell thay cho Git Bash

Bước 1 vẫn phải làm trong Git Bash (hoặc theo cách cài thủ công). Sau đó chạy một lần trong PowerShell để thêm Foundry vào PATH, rồi mở terminal mới:

```powershell
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$userPath;$env:USERPROFILE\.foundry\bin", "User")
```

Các bước 3–6 trong PowerShell. `anvil` vẫn chạy ở một cửa sổ riêng, còn `http.server` chiếm cửa sổ cho tới khi nhấn Ctrl+C.

```powershell
cd C:\dev\clearswap
forge build; if ($?) { forge test -vv }
forge fmt --check

$env:ANVIL0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $env:ANVIL0
Get-Content deployments/anvil.json

python -m http.server 8000 --bind 127.0.0.1

cmd /c "forge test --gas-report --match-path test/experiments/GasScenarios.t.sol > docs\gas-report.txt"
forge test --match-path test/experiments/SandwichSweep.t.sol
Get-Content out-experiments/sandwich.csv -TotalCount 25
Get-FileHash out-experiments/sandwich.csv
```

Những chỗ khác với Git Bash:

- Biến môi trường viết là `$env:TÊN`.
- Windows PowerShell 5.1 không có `&&`; thay bằng `; if ($?) { … }`. PowerShell 7 thì có `&&`.
- Không ghi output của `forge` bằng `>` của PowerShell 5.1: file sẽ ở dạng UTF-16 và ký tự kẻ bảng bị lỗi. Vì vậy lệnh ở trên dùng `cmd /c`, vốn ghi nguyên byte.
- Lệnh `python3` có thể mở Microsoft Store thay vì Python, nên dùng `python` hoặc `py`.

Trong VS Code cũng có thể mở terminal Git Bash bằng nút ⌄ cạnh dấu `+` của khung terminal.

### Sự cố thường gặp trên Windows

| Thông báo | Cách xử lý |
|---|---|
| `bash: forge: command not found` (Git Bash) | `source ~/.bashrc` hoặc mở Git Bash mới; kiểm tra dòng PATH ở bước 1 |
| PowerShell: `The term 'forge' is not recognized` | thêm Foundry vào PATH như ở [mục PowerShell](#dùng-powershell-thay-cho-git-bash), rồi mở terminal mới |
| `unable to create file … Permission denied` khi clone | Windows Defender khóa file; chạy `git submodule update --init --recursive` |
| `Filename too long` | `git config --global core.longpaths true` và đặt repo ở đường dẫn ngắn |
| `forge fmt --check` báo lệch ở mọi file | file đang ở dạng CRLF vì repo được clone trước khi có `.gitattributes`. Chạy `forge fmt` một lần, hoặc clone lại |
| Thí nghiệm báo lỗi khi ghi `sandwich.csv` | đóng file trong Excel rồi chạy lại |

WSL2 (Ubuntu) cũng dùng được: làm theo hướng dẫn macOS, bỏ bước `xcode-select`. WSL2 cần Windows 10 bản 1903 trở lên.

## Tham khảo chung

Phần này giống nhau trên mọi máy.

### Thư viện và kiểu xuống dòng

Thư viện được ghim phiên bản qua submodule: `lib/openzeppelin-contracts` ở tag `v5.1.0`, `lib/forge-std` ở tag `v1.17.0`.

File `.gitattributes` buộc file của dự án dùng LF trên mọi máy, kể cả Windows có `core.autocrlf=true`, nên `forge fmt --check` cho cùng kết quả ở mọi máy. Riêng thư viện trong `lib/` là submodule nên không chịu `.gitattributes` này, và trên Windows vẫn là CRLF. Điều đó không ảnh hưởng việc biên dịch hay số gas; chỉ phần hash metadata ở cuối bytecode có thể khác giữa hai máy. Muốn bytecode giống hệt từng byte thì chạy `git config --global core.autocrlf input` trước khi clone.

### Chạy test theo từng phase

```bash
forge test --match-path test/Token.t.sol                  # Phase 1
forge test --match-path test/Exchange.t.sol               # Phase 2
forge test --match-path test/Fees.t.sol                   # Phase 3
forge test --match-path test/Ledger.t.sol                 # Phase 4
forge test --match-path "test/attacks/*.t.sol"            # FakePath, Reentrancy, Drain
forge test --match-path test/Settle.t.sol                 # Phase 5
forge test --match-path test/invariants/Invariants.t.sol  # Phase 8: I1–I8
```

`forge test -vv` chạy tất cả: unit, fuzz (512 lần) và invariant (64 × 32). Các lệnh trên chạy nguyên văn trong zsh, Git Bash và PowerShell.

### Script deploy làm gì

`script/Deploy.s.sol` deploy `Token`, `Exchange(token)` và `Ledger(token, exchange)`, mint 20,000 CSU, tạo pool 5,000 ETH / 5,000 CSU, chuyển 1,000 CSU cho mỗi tài khoản Anvil #1–#5. Cuối cùng nó ghi `{token, exchange, ledger, deployBlock, chainId}` vào `deployments/anvil.json` để web app đọc.

### Web app

Trang phải được mở qua `http://` từ server chạy ở **thư mục gốc** repo, để đọc được `../deployments/anvil.json`. Mở thẳng file `index.html` sẽ không chạy. Trang cũng cần Internet để tải ethers v6 từ cdnjs.

Trang kết nối `http://127.0.0.1:8545` và cho chọn tài khoản ký giao dịch trong 10 tài khoản Anvil. Danh sách người dùng của sổ nợ thì lấy từ sự kiện `IOUAdded`/`Settled`. Ô "Chủ nợ" nhận địa chỉ đầy đủ, hoặc `#n` cho tài khoản Anvil số n.

Các hàm JS (đều `async`, gọi được từ console): `getUsers`, `getTotalOwed`, `getLastActive`, `add_IOU`, `settleWithTokens`, `settleWithETH`, `addLiquidity`, `removeLiquidity`, `removeAllLiquidity`, `swapETHForTokens`, `swapTokensForETH`.

### Kịch bản kiểm tra web app

Kịch bản A–B–C, với A = #1, B = #2, C = #3:

1. Chọn **#1**, Ghi nợ: chủ nợ `#2`, 100.
2. Chọn **#2**, Ghi nợ: chủ nợ `#3`, 100.
3. Chọn **#3**, Ghi nợ: chủ nợ `#1`, 60. Client tìm ra chu trình #3 → #1 → #2 → #3 và gửi path, nên bảng chỉ còn **#1 → #2: 40** và **#2 → #3: 40**.
4. Chọn **#1**, Trả nợ bằng ETH: chủ nợ `#2`, 40, trượt giá 5%. Sau đó #2 có thêm 40 CSU (1,000 → 1,040), bảng nợ không còn #1 → #2, và ô "Ledger đang giữ" hiển thị `0 ETH, 0 CSU`.

### Kiểm tra chấp nhận cuối cùng

Làm đủ bước 3–6 trong hướng dẫn cho hệ điều hành của bạn. Theo đặc tả, dự án đạt khi:

- mọi test xanh (kể cả invariant) và `forge fmt --check` sạch;
- 8 bất biến I1–I8 đều có test (bảng trong [docs/DESIGN.md](docs/DESIGN.md));
- 3 file trong `test/attacks/` revert đúng chỗ;
- `out-experiments/sandwich.csv` có vùng revert khi s nhỏ (cách đọc: [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md));
- web app chạy được kịch bản A–B–C;
- người khác làm theo README chạy lại được.

## Tương thích: Windows và MacBook Air

**Đánh giá: chạy được trên cả hai, nhưng chưa chạy thử thực tế trên máy nào.** Trong mã không có phần nào phụ thuộc hệ điều hành:

- Hợp đồng, test, invariant và thí nghiệm chạy trong EVM của Foundry. Vì vậy kết quả test, số gas và file `sandwich.csv` phải giống hệt nhau trên mọi máy.
- Script và test chỉ ghi file bằng đường dẫn tương đối dùng `/` (`out-experiments/…`, `deployments/…`). Foundry (viết bằng Rust) chấp nhận dạng này trên Windows.
- Web app là HTML/JS thuần chạy trong trình duyệt. Nó chỉ cần một web server tĩnh (Python) và Internet để tải ethers từ cdnjs.

Khác biệt chỉ nằm ở **cách cài công cụ** và **cú pháp lệnh trong terminal**; hai hướng dẫn ở trên đã tách riêng các khác biệt này.

| Thành phần | Windows 10/11 (x64) | MacBook Air (macOS) |
|---|---|---|
| Foundry `forge` / `cast` / `anvil` | bản `win32_amd64`; cài bằng `foundryup` trong **Git Bash** | bản `darwin_arm64` (chip M1–M4) hoặc `darwin_amd64` (Intel); cài bằng `foundryup` |
| solc 0.8.28 (forge tự tải ở lần build đầu, cần Internet) | `solc-windows-amd64` | universal binary (x86_64 + arm64), chạy gốc trên Apple Silicon, không cần Rosetta |
| Terminal dùng trong hướng dẫn | Git Bash (hoặc PowerShell với lệnh riêng) | zsh (mặc định) |
| Web server cho web app | `python` hoặc `py` | `python3` (có sau `xcode-select --install`) |
| Trình duyệt | Edge, Chrome, Firefox | Safari, Chrome, Firefox |

### Đã kiểm tra những gì

Ngày 31/10/2026, trên máy phát triển (Windows 10 Enterprise LTSC 2019 bản 1809, Git Bash, Python 3.11):

| Hạng mục | Kết quả |
|---|---|
| Phụ thuộc hệ điều hành trong mã (đường dẫn tuyệt đối, dấu `\`, `vm.ffi`, gọi shell) | không có |
| Foundry v1.8.5 có bản build cho cả hai nền tảng | có: `win32_amd64`, `darwin_arm64`, `darwin_amd64` |
| Script cài Foundry hiện tại (`foundryup-init 2.0.0`) | nhận diện Git Bash (`MINGW*`/`MSYS*`); cài vào `~/.foundry/bin` nhưng không tự thêm PATH (vì vậy bước 1 có dòng thêm PATH) |
| solc 0.8.28 cho macOS là universal binary | có: header Mach-O `cafebabe`, 2 kiến trúc |
| `python -m http.server --bind 127.0.0.1` phục vụ `web_app/` | đạt; MIME đúng: `text/html`, `application/javascript`, `text/css` |
| Đường dẫn dài nhất trong `lib/` | 139 ký tự, dưới giới hạn 260 của Windows |
| Cú pháp `web_app/app.js` (`node --check`) | đạt |
| Kiểu xuống dòng | máy này đặt `core.autocrlf=true` nên file do git checkout ra là CRLF (25/25 file kiểm trong `lib/`), còn macOS mặc định giữ LF. Đã thêm `.gitattributes` để file của dự án luôn là LF |
| `forge build`, `forge test`, `forge fmt --check` trên Windows | **chưa chạy**: máy chưa cài Foundry |
| Mọi bước trên macOS | **chưa chạy**: chưa có máy Mac để thử |

Hai dòng cuối là việc còn lại; làm theo [Kiểm chứng trên từng máy](#kiểm-chứng-trên-từng-máy).

### Kiểm chứng trên từng máy

Windows: chạy trong Git Bash. macOS: chạy trong Terminal.

```bash
forge --version
forge build
forge test -vv                                                # mọi test phải xanh
forge fmt --check                                             # không file nào lệch định dạng
forge test --match-path test/experiments/SandwichSweep.t.sol
shasum -a 256 out-experiments/sandwich.csv                    # Git Bash: sha256sum
```

Đạt khi trên cả hai máy:

- mọi test xanh;
- `forge fmt --check` sạch;
- mã băm của `sandwich.csv` trùng nhau;
- [kịch bản kiểm tra web app](#kịch-bản-kiểm-tra-web-app) cho cùng kết quả.

Có thể so thêm số gas trong `docs/gas-report.txt` của hai máy; chúng phải bằng nhau.

## Gỡ lỗi chung

Các lỗi riêng của từng hệ điều hành nằm trong bảng "Sự cố thường gặp" của hướng dẫn tương ứng.

- **Trang báo "Không đọc được ../deployments/anvil.json":** server phải chạy ở thư mục gốc repo (không phải trong `web_app/`), và bước deploy phải đã chạy xong.
- **Trang báo "Không có hợp đồng tại địa chỉ Ledger":** `anvil` đã khởi động lại; hãy chạy lại bước deploy.
- **`forge script` không kết nối được `127.0.0.1:8545`:** `anvil` chưa chạy, hoặc chưa khởi động xong.
- **`forge build` không thấy `@openzeppelin/...`:** chưa có submodule; chạy `git submodule update --init --recursive`.
- **`forge build` lỗi khi tải solc:** lần build đầu cần Internet để tải solc 0.8.28; các lần sau Foundry dùng bản đã lưu.
