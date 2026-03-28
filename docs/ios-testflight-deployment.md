# iOS TestFlight / App Store 部署指南

> ArcanaKit iOS App 從 CI/CD 到 App Store Connect 的完整上架流程技術文件

---

## 目錄

1. [概述](#1-概述)
2. [基礎設施架構](#2-基礎設施架構)
3. [Fastlane 設定](#3-fastlane-設定)
4. [Code Signing（fastlane match）](#4-code-signingfastlane-match)
5. [Jenkins Pipeline 設定](#5-jenkins-pipeline-設定)
6. [App Store Connect Metadata](#6-app-store-connect-metadata)
7. [Screenshots](#7-screenshots)
8. [問題排除記錄](#8-問題排除記錄)
9. [實用指令](#9-實用指令)

---

## 1. 概述

本文件涵蓋 ArcanaKit iOS App 上架至 App Store Connect（TestFlight / App Store）的完整 CI/CD 流程。

### 涉及系統

| 系統 | 角色 |
|------|------|
| **Jenkins (bluesea)** | CI/CD 主控節點，Oracle Cloud ARM64 |
| **Mac Mini (macos agent)** | JNLP WebSocket Agent，執行 Xcode build、test、fastlane deploy |
| **App Store Connect** | Apple 應用發佈平台，透過 API Key 認證 |
| **fastlane** | 自動化 code signing、build、upload、metadata 管理 |

### 流程概覽

```
Git Push → Jenkins 偵測 → Checkout (macos) → Build → Test + Coverage (macos)
    → SonarQube Analysis (built-in) → fastlane beta (macos) → TestFlight
```

---

## 2. 基礎設施架構

### Jenkins (bluesea — Oracle Cloud)

- **主機**: `161.118.206.170`（SSH alias `bluesea`）
- **OS**: Rocky Linux 9.7, ARM64 (aarch64), 24GB RAM
- **Jenkins URL**: `https://arcana.boo/jenkins/`
- **認證**: admin/admin，前端有 Authelia 2FA

### Mac Mini (macos agent)

- **主機**: `192.168.11.104`（SSH alias `macmini`）
- **OS**: macOS 15.6, Apple Silicon (ARM64)
- **Xcode**: 26.2
- **Agent 類型**: JNLP WebSocket（`-webSocket` mode）
- **Label**: `macos`
- **Launchd Service**: `com.jenkins.agent`
- **SSH Key**: ed25519 at `~/.ssh/id_ed25519`，已加入 bluesea `authorized_keys`

### App Store Connect API Key 認證

本專案**不使用** Apple ID 帳號密碼登入，而是使用 App Store Connect API Key 進行認證。這是 CI/CD 環境的最佳實踐（無需 2FA 互動）。

| 項目 | 值 |
|------|-----|
| **Key ID** | `36K8H6TFR6` |
| **Issuer ID** | `69a6de87-e17a-47e3-e053-5b8c7c11a4d1` |
| **Key 檔案** | `.p8` 格式，存為 Jenkins Secret file credential |
| **權限** | App Manager（需具備 TestFlight + App Store 上傳權限） |

---

## 3. Fastlane 設定

### Gemfile

```ruby
source "https://rubygems.org"

gem "fastlane"
gem "xcpretty"
```

### Fastfile

```ruby
default_platform(:ios)

platform :ios do

  # ---- 主要 lane：簽名 + 建置 + 上傳 TestFlight ----
  desc "Build and upload to TestFlight"
  lane :beta do
    setup_ci  # CI 環境建立暫時 keychain

    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_filepath: ENV["ASC_KEY_PATH"]
    )

    match(type: "appstore", api_key: api_key, readonly: true)

    increment_build_number(
      build_number: ENV["BUILD_NUMBER"] || Time.now.strftime("%Y%m%d%H%M")
    )

    update_code_signing_settings(
      use_automatic_signing: false,
      path: "arcana-ios.xcodeproj",
      team_id: "89YYRF88M3",
      code_sign_identity: "Apple Distribution",
      profile_name: "match AppStore com.arcana.example"
    )

    build_app(
      project: "arcana-ios.xcodeproj",
      scheme: "arcana-ios",
      export_method: "app-store",
      output_directory: "build",
      output_name: "arcana-ios.ipa"
    )

    upload_to_testflight(api_key: api_key, skip_waiting_for_build_processing: true)
  end

  # ---- Metadata 上傳 ----
  desc "Upload metadata to App Store Connect"
  lane :metadata do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_filepath: ENV["ASC_KEY_PATH"]
    )
    deliver(api_key: api_key, skip_binary_upload: true, force: true)
  end

  # ---- 憑證同步 ----
  desc "Sync certificates and profiles"
  lane :certificates do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_filepath: ENV["ASC_KEY_PATH"]
    )
    match(type: "appstore", api_key: api_key)
  end

  # ---- 測試 ----
  desc "Run tests"
  lane :test do
    run_tests(
      project: "arcana-ios.xcodeproj",
      scheme: "arcana-ios",
      device: "iPhone 17"
    )
  end

  # ---- 僅建置 IPA ----
  desc "Build release IPA"
  lane :build_release do
    build_app(
      project: "arcana-ios.xcodeproj",
      scheme: "arcana-ios",
      export_method: "app-store",
      output_directory: "build"
    )
  end

  # ---- 截圖 ----
  desc "Capture screenshots"
  lane :screenshots do
    capture_screenshots
  end
end
```

### Matchfile

```ruby
git_url("ssh://rocky@161.118.206.170/data/devops/fastlane-certificates.git")
storage_mode("git")
type("appstore")
app_identifier("com.arcana.example")
team_id("89YYRF88M3")
```

### Appfile

```ruby
app_identifier("com.arcana.example")
team_id("89YYRF88M3")
```

---

## 4. Code Signing（fastlane match）

### 架構

fastlane match 使用私有 Git Repo 儲存加密的 Certificate 與 Provisioning Profile，確保所有開發者與 CI 環境使用相同的簽名憑證。

```
Mac Mini (CI)
    ↓ git clone (SSH)
bluesea:/data/devops/fastlane-certificates.git  (bare repo)
    ↓ 解密 (MATCH_PASSWORD)
Certificate + Profile → 安裝到 Keychain
```

### 憑證資訊

| 項目 | 值 |
|------|-----|
| **Git Repo** | `ssh://rocky@161.118.206.170/data/devops/fastlane-certificates.git`（bare repo） |
| **加密密碼** | `MATCH_PASSWORD`（Jenkins credential: `match-password`） |
| **Certificate** | Apple Distribution: NXCONTROL SYSTEM CO., LTD. (89YYRF88M3) |
| **Profile** | match AppStore com.arcana.example |
| **Team ID** | 89YYRF88M3 |

### 首次設定

初次在 Mac Mini 上設定 match：

```bash
# 設定環境變數
export ASC_KEY_ID="36K8H6TFR6"
export ASC_ISSUER_ID="69a6de87-e17a-47e3-e053-5b8c7c11a4d1"
export ASC_KEY_PATH="/path/to/AuthKey_36K8H6TFR6.p8"
export MATCH_PASSWORD="ArcanaKit2026!"

# CI=true 強制使用暫時 keychain（SSH 環境必須）
CI=true bundle exec fastlane certificates
```

### 重要注意事項

1. **CI 環境必須使用 `setup_ci`**：SSH/CI session 中 login keychain 是鎖定的，直接匯入憑證會觸發 `SecKeychainItemImport: User interaction not allowed`。`setup_ci`（或 `CI=true`）會建立暫時 keychain 來避免此問題。

2. **Xcode 專案需覆蓋簽名設定**：預設的 Automatic Signing 會嘗試使用 Development profile（CI 環境沒有），必須透過 `update_code_signing_settings` 強制設為 Manual Signing + Distribution profile。

3. **SSH Key 存取**：Mac Mini 必須能透過 SSH 存取 bluesea 上的 bare repo。確認 `~/.ssh/id_ed25519` 已配置且 bluesea 的 `authorized_keys` 包含對應公鑰。

---

## 5. Jenkins Pipeline 設定

### Pipeline 定義檔

`jobs/ios-app.xml`

### Pipeline 階段

```
┌─────────────────────────────────────────────────────┐
│  Stage 1: Checkout          (agent: macos)          │
│  → withCredentials git clone                        │
├─────────────────────────────────────────────────────┤
│  Stage 2: Build             (agent: macos)          │
│  → xcodebuild build (CODE_SIGNING_ALLOWED=NO)      │
├─────────────────────────────────────────────────────┤
│  Stage 3: Test + Coverage   (agent: macos)          │
│  → xcodebuild test on iPhone 17 simulator           │
│  → 轉換 coverage 為 sonar 格式                       │
│  → stash coverage + sources                         │
├─────────────────────────────────────────────────────┤
│  Stage 4: SonarQube Analysis (agent: built-in)      │
│  → unstash → sonar-scanner                          │
├─────────────────────────────────────────────────────┤
│  Stage 5: Deploy to TestFlight (agent: macos)       │
│  → bundle install → fastlane beta                   │
│  → catchError: stageResult UNSTABLE                 │
└─────────────────────────────────────────────────────┘
```

### 環境變數

```groovy
environment {
    PROJECT_NAME   = 'arcana-ios'
    VERSION        = '1.0.0'
    // 注意：不能設為全域 PATH，否則會破壞 built-in agent 上的 sonar-scanner
    MAC_PATH       = "/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    SONAR_TOKEN    = credentials('sonarqube-token')
    SONAR_HOST_URL = 'http://sonarqube:9000/sonarqube'
}
```

> **關鍵設計**：使用 `MAC_PATH` 而非全域 `PATH`，並在每個 macos stage 中 `export PATH=${MAC_PATH}`。若設為全域 `PATH`，built-in agent（Linux）上的 sonar-scanner 會因為找不到 `/opt/sonar-scanner/bin` 而失敗。

### Deploy to TestFlight Stage 細節

```groovy
stage('Deploy to TestFlight') {
    agent { label 'macos' }
    steps {
        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
            withCredentials([
                file(credentialsId: 'asc-api-key', variable: 'ASC_KEY_PATH'),
                string(credentialsId: 'asc-key-id', variable: 'ASC_KEY_ID'),
                string(credentialsId: 'asc-issuer-id', variable: 'ASC_ISSUER_ID'),
                string(credentialsId: 'match-password', variable: 'MATCH_PASSWORD')
            ]) {
                sh '''
                    export PATH=${MAC_PATH}
                    export LC_ALL=en_US.UTF-8
                    export LANG=en_US.UTF-8
                    bundle install --quiet
                    bundle exec fastlane beta
                '''
            }
        }
    }
    post {
        success {
            archiveArtifacts artifacts: 'build/*.ipa', allowEmptyArchive: true
        }
    }
}
```

> **`catchError`**：TestFlight 上傳偶爾有已知問題（如 fastlane deliver bug），使用 `catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE')` 確保整個 pipeline 不會因為上傳問題而標記為 FAILURE。

### Jenkins Credentials 清單

| Credential ID | 類型 | 用途 |
|---------------|------|------|
| `github-credentials` | Username/Password | Git checkout |
| `sonarqube-token` | Secret text | SonarQube analysis token |
| `asc-api-key` | Secret file | App Store Connect API Key (.p8) |
| `asc-key-id` | Secret text | `36K8H6TFR6` |
| `asc-issuer-id` | Secret text | `69a6de87-e17a-47e3-e053-5b8c7c11a4d1` |
| `match-password` | Secret text | fastlane match 加密密碼 |

### 建立缺少的 Jenkins Credentials

透過 Jenkins API 建立 Secret text credential：

```bash
# 取得 CSRF crumb
CRUMB=$(curl -s -u admin:admin -c /tmp/j.cookie \
  "https://arcana.boo/jenkins/crumbIssuer/api/json" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d['crumb'])")

# 建立 Secret text credential
curl -X POST -u admin:admin -b /tmp/j.cookie \
  -H "Jenkins-Crumb: $CRUMB" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  "https://arcana.boo/jenkins/credentials/store/system/domain/_/createCredentials" \
  --data-urlencode 'json={
    "": "0",
    "credentials": {
      "scope": "GLOBAL",
      "id": "asc-key-id",
      "secret": "36K8H6TFR6",
      "description": "App Store Connect Key ID",
      "$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"
    }
  }'
```

---

## 6. App Store Connect Metadata

### 管理方式

透過 fastlane deliver（`fastlane metadata` lane）管理 App Store metadata。

### 目錄結構

```
fastlane/metadata/
├── en-US/
│   ├── name.txt                 # App 名稱
│   ├── subtitle.txt             # 副標題
│   ├── description.txt          # 完整描述
│   ├── keywords.txt             # 搜尋關鍵字
│   ├── privacy_url.txt          # 隱私政策 URL
│   ├── support_url.txt          # 支援 URL
│   └── release_notes.txt        # 版本更新說明
├── zh-Hant/
│   ├── name.txt
│   ├── subtitle.txt
│   ├── description.txt
│   ├── keywords.txt
│   ├── privacy_url.txt
│   ├── support_url.txt
│   └── release_notes.txt
└── review_information/
    ├── demo_password.txt
    ├── demo_user.txt
    ├── email_address.txt
    ├── first_name.txt
    ├── last_name.txt
    └── phone_number.txt
```

### 已知問題

fastlane 2.232.2 在**首次版本上傳**時，`deliver` 在 `review_attachment_file` 步驟會觸發 "No data" 錯誤。但 metadata 在錯誤發生前已成功上傳。此為 fastlane 已知 bug，後續版本可能修復。

---

## 7. Screenshots

### 截圖方式

透過 XCUITest 在 Simulator 上自動截圖：

- **裝置**: iPhone 17 Pro Max（6.9 吋）
- **模式**: App 需啟用 mock mode（`useRealAPI: false`），因為截圖時沒有後端 API

### 尺寸轉換

App Store Connect 要求 6.5 吋裝置截圖（1242x2688），但 6.9 吋 Simulator 輸出為 1320x2868。需要 resize：

```bash
# 將 6.9" 截圖縮放為 6.5" 尺寸
sips -z 2688 1242 screenshot.png
```

### 上傳方式

fastlane deliver 的截圖上傳功能有穩定性問題。建議使用 App Store Connect API 直接上傳，流程為三步驟：

```
1. POST   /appScreenshots          → 建立截圖資源（reserve）
2. PUT    {uploadOperations.url}   → 上傳二進位檔案
3. PATCH  /appScreenshots/{id}     → 確認上傳完成（commit）
```

#### Python 上傳腳本（概要）

```python
import urllib.request
import json

# Step 1: Reserve screenshot slot
body = {
    "data": {
        "type": "appScreenshots",
        "attributes": {
            "fileName": "screenshot_01.png",
            "fileSize": file_size
        },
        "relationships": {
            "appScreenshotSet": {
                "data": { "type": "appScreenshotSets", "id": screenshot_set_id }
            }
        }
    }
}
# POST to App Store Connect API...

# Step 2: Upload binary via PUT to the URL from uploadOperations
# Step 3: PATCH to commit the upload
```

> **注意**：Shell `eval curl` 上傳二進位檔案時容易失敗（`AWAITING_UPLOAD` 狀態），改用 Python `urllib` 更為可靠。

### 語系

同時上傳 `en-US` 和 `zh-Hant` 兩組截圖。

---

## 8. 問題排除記錄

### 8.1 sonar-scanner not found

- **症狀**: SonarQube Analysis stage 失敗，`sonar-scanner: command not found`
- **原因**: 將 `MAC_PATH`（macOS 路徑）設為全域 `PATH` 環境變數，覆蓋了 built-in agent（Linux）上的 PATH，導致 `/opt/sonar-scanner/bin` 不在 PATH 中
- **解法**: 使用 `MAC_PATH` 變數，僅在 macos agent 的 stage 中 `export PATH=${MAC_PATH}`

### 8.2 testPublisherAsync timeout (120s)

- **症狀**: 單元測試 `testPublisherAsync` 在 CI 環境超時 120 秒
- **原因**: 使用 `PassthroughSubject` + `50ms sleep` 的 race condition，在 CI 環境 timing 不穩定
- **解法**: 改用 `CurrentValueSubject`（已有初始值，不依賴 timing）

### 8.3 YOUR_ORG placeholder in git URLs

- **症狀**: Checkout stage git clone 失敗，URL 包含 `YOUR_ORG`
- **原因**: 去敏化處理留下的 placeholder 未替換
- **解法**: 在 bluesea 上 `sed` 替換為實際 org name

### 8.4 xcpretty invalid byte sequence in US-ASCII

- **症狀**: fastlane build 時 xcpretty 報錯 `invalid byte sequence in US-ASCII`
- **原因**: SSH session 未設定 UTF-8 locale
- **解法**: 在 pipeline 中加入：
  ```bash
  export LC_ALL=en_US.UTF-8
  export LANG=en_US.UTF-8
  ```

### 8.5 No Accounts / No profiles

- **症狀**: fastlane match 報錯找不到帳號或 profile
- **原因**: Mac Mini 上 Xcode 未登入 Apple Developer 帳號
- **解法**: 改用 App Store Connect API Key 認證（`app_store_connect_api_key`），不依賴 Xcode 帳號登入

### 8.6 SecKeychainItemImport: User interaction not allowed

- **症狀**: match 匯入憑證到 keychain 時失敗
- **原因**: SSH session 中 login keychain 處於鎖定狀態，無法互動解鎖
- **解法**: 使用 `setup_ci`（或設定 `CI=true`）建立暫時 keychain，繞過 login keychain

### 8.7 No profiles for iOS App Development

- **症狀**: build 時找不到 Development provisioning profile
- **原因**: Xcode 專案預設使用 Automatic Signing，會要求 Development profile（CI 環境沒有）
- **解法**: 在 Fastfile 中加入 `update_code_signing_settings`，強制使用 Manual Signing + Apple Distribution certificate + match AppStore profile

### 8.8 fastlane deliver "No data" error

- **症狀**: `fastlane metadata` 在 `review_attachment_file` 步驟 crash，顯示 "No data"
- **原因**: fastlane 2.232.2 已知 bug，首次版本上傳時觸發
- **解法**: Metadata 在 crash 前已成功上傳，可忽略此錯誤。截圖改用 API 直接上傳

### 8.9 Screenshots stuck at AWAITING_UPLOAD

- **症狀**: 截圖狀態停在 `AWAITING_UPLOAD`，未進入 `COMPLETE`
- **原因**: Shell `eval curl` 上傳二進位檔案時 data 格式錯誤
- **解法**: 改用 Python `urllib.request` 進行 PUT 上傳，確保 binary data 正確傳輸

### 8.10 App Icon not showing in App Store Connect

- **症狀**: App Store Connect 版本頁面沒有顯示 App Icon
- **原因**: Build 已上傳但未 attach 到 appStoreVersions 1.0
- **解法**: 透過 API 將 build 關聯到版本：
  ```bash
  # PATCH appStoreVersions/{version_id}/relationships/build
  curl -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersions/{VERSION_ID}/relationships/build" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d '{"data": {"type": "builds", "id": "BUILD_ID"}}'
  ```

### 8.11 缺少 Jenkins Credentials

- **症狀**: Pipeline 執行時 `asc-key-id` 和 `asc-issuer-id` credential 不存在
- **原因**: 初始設定時只建立了 `asc-api-key`（.p8 檔），忘記建立 Key ID 和 Issuer ID 的 Secret text
- **解法**: 透過 Jenkins API（含 CSRF crumb）建立缺少的 credentials

---

## 9. 實用指令

### 手動觸發 Pipeline

```bash
# 取得 crumb
CRUMB=$(curl -s -u admin:admin -c /tmp/j.cookie \
  "https://arcana.boo/jenkins/crumbIssuer/api/json" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d['crumb'])")

# 觸發建置
curl -X POST -u admin:admin -b /tmp/j.cookie \
  -H "Jenkins-Crumb: $CRUMB" \
  "https://arcana.boo/jenkins/job/ios-app/build"
```

### 同步 Certificates（Mac Mini 上執行）

```bash
cd /path/to/arcana-ios
export ASC_KEY_ID="36K8H6TFR6"
export ASC_ISSUER_ID="69a6de87-e17a-47e3-e053-5b8c7c11a4d1"
export ASC_KEY_PATH="/path/to/AuthKey_36K8H6TFR6.p8"
export MATCH_PASSWORD="ArcanaKit2026!"
CI=true bundle exec fastlane certificates
```

### 上傳 Metadata

```bash
export ASC_KEY_ID="36K8H6TFR6"
export ASC_ISSUER_ID="69a6de87-e17a-47e3-e053-5b8c7c11a4d1"
export ASC_KEY_PATH="/path/to/AuthKey_36K8H6TFR6.p8"
bundle exec fastlane metadata
```

### 產生 App Store Connect JWT Token

```bash
#!/bin/bash
# generate-asc-jwt.sh
# 產生 App Store Connect API JWT token（有效期 20 分鐘）

KEY_ID="36K8H6TFR6"
ISSUER_ID="69a6de87-e17a-47e3-e053-5b8c7c11a4d1"
KEY_PATH="./AuthKey_36K8H6TFR6.p8"

# Header
HEADER=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | \
  openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

# Payload (exp = now + 20 min)
NOW=$(date +%s)
EXP=$((NOW + 1200))
PAYLOAD=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' \
  "$ISSUER_ID" "$NOW" "$EXP" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

# Signature
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | \
  openssl dgst -sha256 -sign "$KEY_PATH" -binary | \
  openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"
echo "$JWT"
```

### 查詢 Build 狀態

```bash
JWT=$(./generate-asc-jwt.sh)

# 列出最近的 builds
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=YOUR_APP_ID&limit=5&sort=-uploadedDate" | \
  python3 -m json.tool

# 查詢特定 build 的 TestFlight 處理狀態
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds/{BUILD_ID}" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
attrs = d['data']['attributes']
print(f\"Version: {attrs['version']}\")
print(f\"Build:   {attrs['uploadedDate']}\")
print(f\"Status:  {attrs['processingState']}\")
"
```

### 查詢 App Store Version 狀態

```bash
JWT=$(./generate-asc-jwt.sh)

# 列出所有版本
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/apps/YOUR_APP_ID/appStoreVersions" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
for v in d['data']:
    attrs = v['attributes']
    print(f\"{attrs['versionString']} - {attrs['appStoreState']}\")
"
```

### Attach Build 到 App Store Version

```bash
JWT=$(./generate-asc-jwt.sh)

curl -X PATCH \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersions/{VERSION_ID}/relationships/build" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"data": {"type": "builds", "id": "{BUILD_ID}"}}'
```

---

## 附錄：完整 Pipeline 時間線

| 階段 | 執行節點 | 預估時間 |
|------|---------|---------|
| Checkout | macos | ~10s |
| Build | macos | ~30s |
| Test + Coverage | macos | ~297s (含 simulator boot) |
| SonarQube Analysis | built-in | ~30s |
| Deploy to TestFlight | macos | ~120s |
| **總計** | | **~8 min** |

---

*最後更新：2026-03-27*
