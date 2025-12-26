# =====================================================
# FH5Bot 發佈腳本（互動式 Auto Commit + 可選 GitHub Release 上傳）
# 目的：本機打 tag + 推 tag + 產出 release zip（只含 runtime 需要的檔案）
# 注意：請使用 UTF-8（無 BOM）
# =====================================================

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

function Prompt-Version {
    $msg = "請輸入要發佈的新版本號 (x.y.z)"
    while ($true) {
        $v = Read-Host $msg
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
        Write-Host "版本格式需為 x.y.z，例如 1.0.1" -ForegroundColor Yellow
    }
}

function Update-VersionFiles([string]$newVersion) {
    $changed = @()

    # ✅ 只更新 version.txt（不再動 version.json）
    if (Test-Path ".\version.txt") {
        Set-Content -Path ".\version.txt" -Value $newVersion -Encoding UTF8
        $changed += "version.txt"
    }

    # manifest.json 若有 version/Version 才更新，沒有就略過（不影響打包）
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
    $allow = @(
        "build_app.ps1",
        "version.txt",
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

    git add -- $files | Out-Null

    # ✅ 關鍵保護：如果沒有任何 staged 內容，就不要 commit
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "提示：允許清單內的檔案沒有任何可提交變更，已跳過 commit。" -ForegroundColor Yellow
        return
    }

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗" }

    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) { throw "git push 失敗" }
}


function Try-Upload-GitHubRelease([string]$tag, [string]$zipPath) {
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

    git fetch $REMOTE --tags --prune --prune-tags 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "遠端 tags 同步完成（使用 --prune-tags）。" -ForegroundColor Cyan
        return
    }

    Write-Host "提示：你的 git 可能不支援 --prune-tags，改用 fallback 同步法。" -ForegroundColor Yellow

    $remoteTags = @{}
    git ls-remote --tags $REMOTE 2>$null | ForEach-Object {
        $parts = $_ -split "\s+"
        if ($parts.Count -lt 2) { return }
        $ref = $parts[1]
        if ($ref -match '^refs/tags/(.+)$') {
            $t = $Matches[1]
            $t = $t -replace '\^\{\}$',''
            if ($t) { $remoteTags[$t] = $true }
        }
    }

    $localTags = git tag | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    foreach ($t in $localTags) {
        if (-not $remoteTags.ContainsKey($t)) {
            Write-Host "刪除本地殘留 tag：$t" -ForegroundColor Yellow
            git tag -d $t 2>$null | Out-Null
        }
    }

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
# Build helpers
# =====================================================
function Get-PythonCmd {
    $PY = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $PY) { throw "找不到 python，請先安裝/設定 PATH" }
    return $PY
}

function Build-MainPyc([string]$outPath) {
    $candidates = @(
        (Join-Path $SRC "__main__.py"),
        (Join-Path $SRC "main.py")
    )

    $srcFile = $null
    foreach ($c in $candidates) {
        if (Test-Path $c) { $srcFile = $c; break }
    }
    if (-not $srcFile) {
        throw "找不到入口 .py（需要 __main__.py 或 main.py 其中之一）"
    }

    Get-PythonCmd | Out-Null

    $pycode = @'
import sys, py_compile
src = sys.argv[1]
out = sys.argv[2]
py_compile.compile(src, cfile=out, dfile="__main__.py")
print("compiled:", src, "->", out)
'@

    & python -c $pycode $srcFile $outPath | Out-Null
    if (-not (Test-Path $outPath)) {
        throw "編譯 __main__.pyc 失敗：$outPath"
    }
}

# =====================================================
# Main
# =====================================================

$dirtyAllowed = Get-ChangedAllowedFiles
Auto-Commit-IfNeeded `
  -files $dirtyAllowed `
  -reason "腳本或版本檔異動" `
  -commitMessage "chore: update release script / version files"

Sync-TagsFromRemote

$LATEST = Get-RemoteLatestVersionOnly
Write-Host ("GitHub 最新版本（遠端）：{0}" -f ($LATEST ? $LATEST : "0"))

$newVersion = Prompt-Version
$TAG = "v$newVersion"
Write-Host "即將發佈版本：$newVersion" -ForegroundColor Green

Write-Host "[1/8] 更新版本檔..."
$updatedFiles = Update-VersionFiles $newVersion

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

Write-Host "[2/8] 建立 tag..."
git tag $TAG
if ($LASTEXITCODE -ne 0) { throw "建立 tag 失敗：$TAG" }

Write-Host "[3/8] 推送 tag..."
git push $REMOTE $TAG
if ($LASTEXITCODE -ne 0) { throw "推送 tag 失敗：$TAG" }

$APP_RELEASE = Join-Path $SRC "app_release"

if (Test-Path $APP_RELEASE) { Remove-Item $APP_RELEASE -Recurse -Force }
New-Item -ItemType Directory -Path $APP_RELEASE | Out-Null
New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "bot") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "assets") | Out-Null

Write-Host "[4/8] 編譯 .py -> .pyc..."
Get-PythonCmd | Out-Null
python -m compileall . | Out-Null

Write-Host "[5/8] 複製 .pyc..."
$BOT_PYCACHE = Join-Path (Join-Path $SRC "bot") "__pycache__"
Ensure-FileExists $BOT_PYCACHE "找不到 bot\__pycache__：$BOT_PYCACHE（請確認 bot 模組已 compileall）"

# ✅ 直接生成 app_release\__main__.pyc（不再依賴 __pycache__\__main__*.pyc）
$mainOut = Join-Path $APP_RELEASE "__main__.pyc"
Build-MainPyc -outPath $mainOut

# -----------------------------------------------------
# bot package：自動生成 __init__.py（不再要求 src 內存在）
# -----------------------------------------------------

# ✅ 一律在 app_release\bot\__init__.py 生成（空檔即可）
$botInitOut = Join-Path (Join-Path $APP_RELEASE "bot") "__init__.py"
New-Item -ItemType File -Path $botInitOut -Force | Out-Null

# ✅ 不再打包 bot\__pycache__\__init__*.pyc（讓執行時自行生成即可）

# -----------------------------------------------------
# bot\*.pyc：照常複製（排除 __init__ 的 pyc）
# -----------------------------------------------------
Get-ChildItem "$BOT_PYCACHE\*.pyc" | Where-Object { $_.Name -notmatch '^__init__\.' } | ForEach-Object {
    $name = ($_.BaseName -replace '\.cpython-\d+$','') + ".pyc"
    Copy-Item $_.FullName (Join-Path (Join-Path $APP_RELEASE "bot") $name) -Force
}

Write-Host "[6/8] 複製資源..."
Ensure-FileExists ".\assets" "找不到 .\assets，請確認資源資料夾存在。"
Copy-Item ".\assets\*" (Join-Path $APP_RELEASE "assets") -Recurse -Force
if (Test-Path ".\default_config.json") { Copy-Item ".\default_config.json" $APP_RELEASE -Force }
if (Test-Path ".\manifest.json")       { Copy-Item ".\manifest.json"       $APP_RELEASE -Force }
if (Test-Path ".\version.txt")         { Copy-Item ".\version.txt"         $APP_RELEASE -Force }

Write-Host "[7/8] 打包 zip..."
$DIST_ZIP = Join-Path $DIST_DIR ("FH5Bot_{0}.zip" -f $TAG)
if (Test-Path $DIST_ZIP) { Remove-Item $DIST_ZIP -Force }
Compress-Archive -Path (Join-Path $APP_RELEASE "*") -DestinationPath $DIST_ZIP -Force

Write-Host "=== 本機打包完成 ===" -ForegroundColor Green
Write-Host "產出檔案：" $DIST_ZIP
Write-Host "GitHub tag：" $TAG

Write-Host "[8/8] 是否要建立/更新 GitHub Release 並上傳這包 zip？"
$doUpload = Confirm-YesNo "是否要建立/更新 GitHub Release 並上傳這包 zip？(Y/N)"
if ($doUpload) {
    Try-Upload-GitHubRelease -tag $TAG -zipPath $DIST_ZIP
    Write-Host "=== GitHub Release 處理完成 ===" -ForegroundColor Green
} else {
    Write-Host "已跳過自動上傳。你要上傳到 GitHub 的正確檔案就是這個：" -ForegroundColor Yellow
    Write-Host "  $DIST_ZIP"
}
