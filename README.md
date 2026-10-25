# PRO X TKL 電量橋接

不依賴 G HUB，直接查詢羅技 PRO X TKL 的 HID++ 電量，提交給 macOS 配件電池服務，讓原生「電池」小工具顯示鍵盤圖示、電量和充電狀態。

## 使用

在這個資料夾開啟終端機：

```sh
./manage.sh install     # 編譯、啟動，並設為登入後自動執行
./manage.sh status      # 服務狀態及系統配件電量
./manage.sh read        # 一次查詢真實電量，不新增小工具項目
./manage.sh activity    # 查看 macOS 閒置秒數及是否允許查詢（不存取鍵盤）
./manage.sh test        # 驗證電量閒置邏輯及 G HUB 控制工具（使用模擬，不操作真實裝置／服務）
./manage.sh stop        # 停止，並停用登入自啟動
./manage.sh start       # 恢復執行及登入自啟動
./manage.sh logs        # 查看最近的日誌
./manage.sh uninstall   # 移除自啟動並停止，保留專案檔案
```

需要 macOS 及 Xcode Command Line Tools 的 clang，無第三方執行期依賴。無需管理員權限。編譯或改動後，執行 `./manage.sh install` 更新。

## G HUB 背景程序檢查與停止

`ghub.sh` 是獨立的隨用隨執行工具，不會新增常駐程序，也不影響鍵盤電量服務。

```sh
./ghub.sh status        # 檢查殘留程序、已載入的服務、自啟動是否被禁用；不改設定
./ghub.sh stop          # 禁用已知自啟動服務、卸載服務，再正常結束殘留程序
./ghub.sh stop --force  # 同上；若 5 秒後仍有殘留，才使用 SIGKILL 強制結束
./ghub.sh restore       # 重新允許自啟動，並載入已安裝的 G HUB 服務
```

- 只匹配 `/Applications/lghub.app/Contents/` 或使用者 `~/Applications/lghub.app/Contents/` 內的執行檔，並管理目前登入使用者的 `com.logi.ghub`、`application.com.logi.ghub.*` 及系統的 `com.logi.ghub.updater`。不使用模糊的 `pkill logi`，不停止 Options+ 或本專案的電量程式。
- `stop` 會先禁止服務自啟動，再卸載它們，最後處理殘留程序；每次發送訊號前重新核對 PID 的程式路徑。不會結束其他登入使用者的 G HUB 程序，遇到這種情況會報告未完成。系統更新服務的停用則影響整台電腦。
- 系統服務或 root 程序需要管理員權限時，會透過終端機的 `sudo` 要求認證。請直接執行腳本，不要對整支腳本使用 sudo。認證失敗會在修改設定前中止；其他中途錯誤會回傳非零狀態，不會假裝成功。
- 成功停止後會再等待 2 秒確認沒有立即重新啟動。停用狀態由 macOS 保存，重啟後仍有效；重新安裝／更新 G HUB 或另有軟體主動啟動它，仍可能需要重新檢查。
- `restore` 是「重新啟用 G HUB」而非還原先前設定快照，會啟用上述 G HUB 服務，可能開始執行 G HUB 背景元件。此命令不會自動執行。
- `status` 的 `startup=disabled` 表示已禁止自啟動，`enabled` 表示明確允許，`default` 表示沒有覆寫，需要配合原服務設定判斷。程序殘留和服務啟用是兩個獨立狀態。
- 工具不移除 G HUB、不改動它的安裝檔案，也不修改鍵盤或音響設定。非標準安裝路徑或未來新增的服務名稱需要調整腳本後才能涵蓋。

## 檔案

- `src/keyboard-battery.c`：完整程式原始碼。
- `bin/keyboard-battery`：編譯後的執行檔。
- `manage.sh`：安裝、啟停、查詢和移除。
- `ghub.sh`：G HUB 殘留檢查、停止／強制停止及恢復。
- `tests/`：閒置邏輯與 G HUB 工具的模擬測試。
- `config/local.keyboard-battery.plist`：安裝時產生的 launchd 設定範本。
- `runtime/`：執行鎖及日誌。只有電量／狀態變化或錯誤時記錄。
- `~/Library/LaunchAgents/local.keyboard-battery.plist`：唯一位於專案外的設定檔，指向本專案的執行檔及日誌。這是 macOS 登入自啟動所需的標準位置。

若要移動或重新命名專案，先 `uninstall`，移動後再 `install`。不要在服務執行時直接刪除此目錄。

## 行為與相容性

- **30 秒沒有鍵盤或滑鼠操作後停止查詢**。每秒只讀取 macOS `IOHIDSystem` 已記錄的閒置計時，不向鍵盤發送資料、不監聽按鍵內容，也不建立防止系統睡眠的宣告。無法讀取閒置狀態時亦停止查詢。
- 恢復操作後約 1 秒內開始更新，不等待原本的 60 秒週期；裝置回應及小工具重新整理另有延遲。持續操作時每 60 秒查詢一次，讀取失敗時只在使用者仍活躍的情況下每 15 秒重試。
- 閒置時保留最後一次成功讀值，這不是即時電量；充電狀態和斷線偵測也暫停更新，恢復操作後重新確認。服務在閒置期間啟動時會等待操作後才首次讀取。`read` 指令同樣遵守閒置限制，`logs` 可查看暫停／恢復及讀值變化時間。
- 每次開啟裝置及發送 HID 查詢前再次檢查閒置狀態，避免一次較長的接收器掃描跨過門檻後繼續查詢。已發出的單次請求無法撤回，最多等待 0.4 秒後釋放連線。
- 判斷依據是整台電腦的輸入閒置時間；只操作滑鼠也算活躍，因此仍可能向已自行休眠的鍵盤查詢。這不是鍵盤休眠狀態偵測，也不保證韌體在活躍使用期間不被查詢喚醒；30 秒閒置後則不再主動查詢。
- 正常停止時撤下電量項目；程序異常退出時，系統亦會回收該程序建立的配件電源。
- 只查詢 HID++ 裝置名稱、電池功能索引及電池狀態。不接收按鍵報告，不改燈效、鍵位、韌體或音響設定。
- 直接 USB 連線 `046d:c352` 已實機驗證。另包含直接藍牙 ID `b382`，以及此電腦上 `c53a`／`c547` 接收器槽位的讀取路徑；接收器只在裝置名稱精確為 `PRO X TKL` 時查詢電量。這些無線路徑尚未經本機實測，不能視為保證相容。
- 讀不到百分比或電池回報錯誤時，不發布猜測的數值。
- 電池發布使用 Apple IOKit 未公開介面 `IOPSCreatePowerSource`／`IOPSSetPowerSourceDetails`／`IOPSReleasePowerSource`。已在目前 macOS 驗證；未來系統更新可能需要調整。
- 程式不啟動或修改 G HUB。使用者先前停用的 G HUB 服務維持原狀。
- 本工具只處理一台 PRO X TKL；不修改或隱藏 Tivoo 等其他裝置的電量。

## 協定參考

- [Solaar 的 HID++ 電池解析](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/hidpp20.py)：Unified Battery `0x1004`、GetStatus 功能 `0x10`。
- [PRO X TKL 功能記錄](https://github.com/pwr-Solaar/Solaar/issues/3155)：USB ID、裝置名稱及電池功能。
- [Apple IOKit 私有電源介面宣告](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h)。
- [配件電池橋接實驗記錄](https://github.com/bkovacev/keychron-macos/blob/main/docs/RESEARCH.md)。
