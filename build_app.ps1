# =====================================================
# FH5Bot 發佈腳本（互動式 Auto Commit + 可選 GitHub Release 上傳）
# 目的：本機打 tag + 推 tag + 產出 release zip（只含 runtime 需要的檔案）
# 注意：請使用 UTF-8（無 BOM）
# =====================================================

# ---------- PowerShell / Encoding ----------
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {}

$ErrorActionPreference = "Stop"

# ---------- 基本設定 ----------
$REMOTE = "origin"
$GITHUB_OWNER = "future830759"
$GITHUB_REPO  = "FH5Bot"

$SRC = (Get-Location).Path
$DIST_DIR = Join-Path $SRC "dist"
New-Item -ItemType Directory -Path $DIST_DIR -Force | Out-Null

# ---------- 小工具 ----------
function Ensure-FileExists($path, $msg) {
    if (-not (Test-Path $path)) { throw $msg }
}

function Confirm-YesNo([string]$prompt) {
    while ($true) {
        $ans = Read-Host $prompt
        if ($ans -match '^(y|Y)$') { return $true }
        if ($ans -match '^(n|N)$') { return $false }
        Write-Host "請輸入 Y 或 N" -ForegroundColor Yellow
    }
}

function Prompt-Version([string]$latestRemote) {
    $msg = "請輸入要發佈的新版本號 (x.y.z)"
    if ($latestRemote) { $msg = "$msg，遠端最新為 $latestRemote" }
    while ($true) {
        $v = Read-Host $msg
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
        Write-Host "版本格式需為 x.y.z，例如 1.0.1" -ForegroundColor Yellow
    }
}

function Update-VersionFiles([string]$newVersion) {
    $changed = @()

    if (Test-Path ".\version.txt") {
        Set-Content -Path ".\version.txt" -Value $newVersion -Encoding UTF8
        $changed += "version.txt"
    }

    if (Test-Path ".\version.json") {
        try {
            $obj = Get-Content ".\version.json" -Raw | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains "version") {
                $obj.version = $newVersion
                ($obj | ConvertTo-Json -Depth 10) | Set-Content ".\version.json" -Encoding UTF8
                $changed += "version.json"
            } else {
                # 沒有 version 欄位就不動它
            }
        } catch {
            # version.json 不是標準 JSON 或其他原因，就不動它
        }
    }

    if (Test-Path ".\manifest.json") {
        try {
            $m = Get-Content ".\manifest.json" -Raw | ConvertFrom-Json
            $hasKey = $false
            if ($m -and $m.PSObject.Properties.Name -contains "version") { $m.version = $newVersion; $hasKey = $true }
            if ($m -and $m.PSObject.Properties.Name -contains "Version") { $m.Version = $newVersion; $hasKey = $true }

            if ($hasKey) {
                ($m | ConvertTo-Json -Depth 50) | Set-Content ".\manifest.json" -Encoding UTF8
                $changed += "manifest.json"
            } else {
                Write-Host "警告：manifest.json 找不到 version/Version 欄位，已跳過更新（不影響打包）。" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "警告：manifest.json 解析失敗，已跳過更新（不影響打包）。" -ForegroundColor Yellow
        }
    }

    return $changed
}

function Get-ChangedAllowedFiles {
    # 只檢查允許清單內的異動（避免把不該 commit 的東西一起帶進去）
    $allow = @(
        "build_app.ps1",
        "version.txt",
        "version.json",
        "manifest.json"
    )

    $status = git status --porcelain
    if (-not $status) { return @() }

    $changed = @()
    foreach ($line in $status) {
        $path = $line.Substring(3).Trim()
        if ($allow -contains $path) { $changed += $path }
    }
    return $changed | Select-Object -Unique
}

function Auto-Commit-IfNeeded([string[]]$files, [string]$reason, [string]$commitMessage) {
    if (-not $files -or $files.Count -eq 0) { return }

    Write-Host "偵測到目前工作目錄有變動（允許清單內），可先自動 commit 後再繼續發佈：" -ForegroundColor Cyan
    foreach ($f in $files) { Write-Host " - $f" }
    $do = Confirm-YesNo "是否要自動 commit 以上變動？(Y/N)"
    if (-not $do) { throw "已取消：請先自行 commit ($reason)" }

    git add -- $files
    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗" }
    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) { throw "git push 失敗" }
}

function Try-Upload-GitHubRelease([string]$tag, [string]$zipPath) {
    # 需要：GitHub CLI (gh) 已登入
    try {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh) {
            Write-Host "找不到 gh（GitHub CLI），已跳過自動上傳。" -ForegroundColor Yellow
            return
        }

        $title = $tag
        $notes = "Release $tag"

        gh release view $tag --repo "$GITHUB_OWNER/$GITHUB_REPO" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Release 已存在，更新資產..." -ForegroundColor Cyan
            gh release upload $tag $zipPath --clobber --repo "$GITHUB_OWNER/$GITHUB_REPO"
        }
        else {
            Write-Host "建立 Release..." -ForegroundColor Cyan
            gh release create $tag $zipPath -t $title -n $notes --repo "$GITHUB_OWNER/$GITHUB_REPO"
        }
    }
    catch {
        Write-Host "gh release 操作失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# =====================================================
# Tags：只信遠端 + 執行時同步本地 tags（刪掉遠端已刪除者）
# =====================================================
function Sync-TagsFromRemote {
    Write-Host "正在同步遠端 tags（包含清掉本地已不存在的 tags）..." -ForegroundColor Cyan

    # 優先：新版 git 支援 prune-tags
    git fetch $REMOTE --tags --prune --prune-tags 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "遠端 tags 同步完成（使用 --prune-tags）。" -ForegroundColor Cyan
        return
    }

    # fallback：舊 git 不支援 --prune-tags
    Write-Host "提示：你的 git 可能不支援 --prune-tags，改用 fallback 同步法。" -ForegroundColor Yellow

    # 1) 取遠端 tags
    $remoteTags = @{}
    git ls-remote --tags $REMOTE 2>$null | ForEach-Object {
        # 格式：<sha>\trefs/tags/v1.0.0  或 refs/tags/v1.0.0^{}
        $parts = $_ -split "\s+"
        if ($parts.Count -lt 2) { return }
        $ref = $parts[1]
        if ($ref -match '^refs/tags/(.+)$') {
            $t = $Matches[1]
            # 去掉 annotated tag 的 ^{}
            $t = $t -replace '\^\{\}$',''
            if ($t) { $remoteTags[$t] = $true }
        }
    }

    # 2) 刪掉本地多餘 tags（只針對 vX.Y.Z）
    $localTags = git tag | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    foreach ($t in $localTags) {
        if (-not $remoteTags.ContainsKey($t)) {
            Write-Host "刪除本地殘留 tag：$t" -ForegroundColor Yellow
            git tag -d $t 2>$null | Out-Null
        }
    }

    # 3) 再 fetch tags（補齊遠端 tags）
    git fetch $REMOTE --tags 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "同步遠端 tags 失敗（fallback）" }

    Write-Host "遠端 tags 同步完成（fallback）。" -ForegroundColor Cyan
}

function Get-RemoteLatestVersionOnly {
    $tags = git tag | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    if (-not $tags) { return $null }
    $versions = $tags | ForEach-Object { $_ -replace '^v','' }
    return ($versions | Sort-Object { [version]$_ } | Select-Object -Last 1)
}

# =====================================================
# Main
# =====================================================

# 先處理「腳本本身」若有改動：允許自動 commit
$dirtyAllowed = Get-ChangedAllowedFiles
Auto-Commit-IfNeeded `
  -files $dirtyAllowed `
  -reason "腳本或版本檔異動" `
  -commitMessage "chore: update release script / version files"

# ✅ 只信遠端：執行時同步 tags（包含刪掉本地殘留）
Sync-TagsFromRemote

# ✅ 只用遠端同步後的結果（不再 fallback 本地）
$LATEST = Get-RemoteLatestVersionOnly
Write-Host ("GitHub 最新版本（遠端）：{0}" -f ($LATEST ? $LATEST : "0"))

# 輸入新版本
$newVersion = Prompt-Version $LATEST
$TAG = "v$newVersion"
Write-Host "即將發佈版本：$newVersion" -ForegroundColor Green

# [1/8] 更新版本檔
Write-Host "[1/8] 更新版本檔..."
$updatedFiles = Update-VersionFiles $newVersion

# 若版本檔有異動，建議先 commit
if ($updatedFiles -and $updatedFiles.Count -gt 0) {
    Write-Host "版本檔已更新，建議先 commit 再打 tag/發佈：" -ForegroundColor Cyan
    foreach ($f in $updatedFiles) { Write-Host " - $f" }

    $doCommit = Confirm-YesNo "是否要自動 commit 以上變動？(Y/N)"
    if (-not $doCommit) { throw "已取消：請先自行 commit 版本檔再重新執行。" }

    git add -- $updatedFiles
    git commit -m "chore: release $TAG"
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗" }
    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) { throw "git push 失敗" }
}

# [2/8] 建立 tag（本地）
Write-Host "[2/8] 建立 tag..."
git tag $TAG
if ($LASTEXITCODE -ne 0) { throw "建立 tag 失敗：$TAG" }

# [3/8] 推送 tag
Write-Host "[3/8] 推送 tag..."
git push $REMOTE $TAG
if ($LASTEXITCODE -ne 0) { throw "推送 tag 失敗：$TAG" }

# --------- 以下為打包流程 ---------

$APP_RELEASE = Join-Path $SRC "app_release"

# 路徑準備
if (Test-Path $APP_RELEASE) { Remove-Item $APP_RELEASE -Recurse -Force }
New-Item -ItemType Directory -Path $APP_RELEASE | Out-Null

New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "bot") | Out-Null
New-Item -ItemType Directory -Path (Join-Path (Join-Path $APP_RELEASE "bot") "__pycache__") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "assets") | Out-Null

# [4/8] 編譯 .py -> .pyc
Write-Host "[4/8] 編譯 .py -> .pyc..."
$PY = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $PY) { throw "找不到 python，請先安裝/設定 PATH" }

python -m compileall . | Out-Null

# [5/8] 複製 .pyc（__main__ + bot）
Write-Host "[5/8] 複製 .pyc..."
$LAUNCHER_PYCACHE = Join-Path $SRC "__pycache__"                 # 專案根目錄 __pycache__
$BOT_PYCACHE      = Join-Path (Join-Path $SRC "bot") "__pycache__"

Ensure-FileExists $LAUNCHER_PYCACHE "找不到 __pycache__：$LAUNCHER_PYCACHE（請確認已 compileall）"
Ensure-FileExists $BOT_PYCACHE      "找不到 bot\__pycache__：$BOT_PYCACHE（請確認 bot 模組已 compileall）"

# __main__.pyc（entrypoint）
$mainPyc = Get-ChildItem "$LAUNCHER_PYCACHE\__main__*.pyc" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mainPyc) { throw "找不到 __main__ 的 .pyc（__pycache__\__main__*.pyc）" }
Copy-Item $mainPyc.FullName (Join-Path $APP_RELEASE "__main__.pyc") -Force

# bot\__init__.py（確保 bot 是 package）
if (-not (Test-Path ".\bot\__init__.py")) { throw "找不到 bot\__init__.py" }
Copy-Item ".\bot\__init__.py" (Join-Path (Join-Path $APP_RELEASE "bot") "__init__.py") -Force

# bot\__pycache__\__init__*.pyc（保留原檔名，例如 __init__.cpython-311.pyc）
$initPyc = Get-ChildItem "$BOT_PYCACHE\__init__*.pyc" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $initPyc) { throw "找不到 bot 的 __init__.pyc（bot\__pycache__\__init__*.pyc）" }
Copy-Item $initPyc.FullName (Join-Path (Join-Path (Join-Path $APP_RELEASE "bot") "__pycache__") $initPyc.Name) -Force

# bot\*.pyc（改名去掉 cpython-311 後綴，放在 bot\ 目錄）
Get-ChildItem "$BOT_PYCACHE\*.pyc" | ForEach-Object {
    $name = ($_.BaseName -replace '\.cpython-\d+$','') + ".pyc"
    Copy-Item $_.FullName (Join-Path (Join-Path $APP_RELEASE "bot") $name) -Force
}

# [6/8] 複製資源
Write-Host "[6/8] 複製資源..."
Ensure-FileExists ".\assets" "找不到 .\assets，請確認資源資料夾存在。"
Copy-Item ".\assets\*" (Join-Path $APP_RELEASE "assets") -Recurse -Force
if (Test-Path ".\default_config.json") { Copy-Item ".\default_config.json" $APP_RELEASE -Force }
if (Test-Path ".\manifest.json")       { Copy-Item ".\manifest.json"       $APP_RELEASE -Force }
if (Test-Path ".\version.txt")         { Copy-Item ".\version.txt"         $APP_RELEASE -Force }
# (已移除) 不再打包 version.json

# [7/8] 打包 zip（只打包 app_release 的內容）
Write-Host "[7/8] 打包 zip..."
$DIST_ZIP = Join-Path $DIST_DIR ("FH5Bot_{0}.zip" -f $TAG)
if (Test-Path $DIST_ZIP) { Remove-Item $DIST_ZIP -Force }
Compress-Archive -Path (Join-Path $APP_RELEASE "*") -DestinationPath $DIST_ZIP -Force

Write-Host "=== 本機打包完成 ===" -ForegroundColor Green
Write-Host "產出檔案：" $DIST_ZIP
Write-Host "GitHub tag：" $TAG

# [8/8] 是否上傳 GitHub Release
$doUpload = Confirm-YesNo "是否要建立/更新 GitHub Release 並上傳這包 zip？(Y/N)"
if ($doUpload) {
    Try-Upload-GitHubRelease -tag $TAG -zipPath $DIST_ZIP
    Write-Host "=== GitHub Release 處理完成 ===" -ForegroundColor Green
} else {
    Write-Host "已跳過自動上傳。你要上傳到 GitHub 的正確檔案就是這個：" -ForegroundColor Yellow
    Write-Host "  $DIST_ZIP"
}
