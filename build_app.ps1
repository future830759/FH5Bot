# =====================================================
# FH5Bot 發佈腳本（互動式 Auto Commit + 可選 GitHub Release 上傳）
# 目的：本機打包的 zip = GitHub Release 資產 zip（完全一致）
# =====================================================

$ErrorActionPreference = "Stop"

# ---------- 盡量確保主控台能輸出中文 ----------
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

function Get-DefaultRemoteName {
    # 優先使用 origin，否則取第一個 remote
    $remotes = @(git remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remotes -or $remotes.Count -eq 0) { return "origin" }
    if ($remotes -contains "origin") { return "origin" }
    return $remotes[0]
}

$REMOTE = Get-DefaultRemoteName

# ===== 強制 PowerShell 7+（中文提示，避免 emoji）=====
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "錯誤：請使用 PowerShell 7+（pwsh）執行此腳本。" -ForegroundColor Red
    Write-Host "請在 Windows Terminal 或 PowerShell 7 開啟後執行：pwsh -File .\build_app.ps1" -ForegroundColor Yellow
    exit 1
}

# ================== 參數 / 專案設定 ==================
$SRC = (Get-Location).Path

$GITHUB_OWNER = "future830759"
$GITHUB_REPO  = "FH5Bot"

# 允許自動 commit 的檔案（版本 + 發佈腳本本身）
$ALLOWED_AUTO_COMMIT = @("version.txt", "version.json", "manifest.json", "build_app.ps1")

# ---------- functions ----------
function Validate-SemVer([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    return ($v -match '^\d+\.\d+\.\d+$')
}

function Ensure-GitRepo {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "目前資料夾不是 Git repo（找不到 .git）。請切到真正的專案根目錄再執行。"
    }
}

function Ensure-Remote {
    param([string]$RemoteName = $REMOTE)

    $u = git remote get-url $RemoteName 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($u)) {
        throw "找不到 remote '$RemoteName'。請先設定：git remote add $RemoteName <repo-url>（或將遠端命名為 origin）"
    }
}

function Confirm-YesNo([string]$msg) {
    while ($true) {
        $ans = (Read-Host $msg).Trim().ToLower()
        if ($ans -in @("y","yes")) { return $true }
        if ($ans -in @("n","no")) { return $false }
        Write-Host "請輸入 Y 或 N" -ForegroundColor Yellow
    }
}

function Get-ChangedFiles {
    $out = git status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }

    $files = @()
    foreach ($l in $out) {
        if ($l.Length -lt 4) { continue }
        $path = $l.Substring(3).Trim()
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $files += $path
        }
    }
    return $files
}

function AutoCommit-IfAllowed([string]$reason, [string]$commitMessage) {
    $changed = Get-ChangedFiles
    if ($changed.Count -eq 0) { return }

    $illegal = @($changed | Where-Object { $ALLOWED_AUTO_COMMIT -notcontains $_ })
    if ($illegal.Count -gt 0) {
        Write-Host "錯誤：偵測到非允許自動 commit 的變動，為了安全已中止：" -ForegroundColor Red
        $illegal | ForEach-Object { Write-Host " - $_" }
        throw "請先手動 commit/還原上述檔案後再發佈。"
    }

    Write-Host $reason -ForegroundColor Cyan
    $changed | ForEach-Object { Write-Host " - $_" }

    $doIt = Confirm-YesNo "是否要自動 commit 以上變動？(Y/N)"
    if (-not $doIt) {
        throw "你選擇不自動 commit。請手動處理變動後再重新執行。"
    }

    foreach ($f in $ALLOWED_AUTO_COMMIT) {
        if (Test-Path $f) { git add $f 2>$null }
    }

    # 也要把刪除納入 staged
    git add -u 2>$null

    $st = git diff --cached --name-only 2>$null
    if (-not $st) {
        Write-Host "沒有 staged 變更，略過 commit。" -ForegroundColor Yellow
        return
    }

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗，請檢查衝突或 hook。" }

    # 推送：若遇到 non-fast-forward，先 fetch + rebase 再推
    $branch = (git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "master" }

    git fetch $REMOTE | Out-Null
    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "偵測到遠端比本機新，嘗試 git pull --rebase 後再推一次..." -ForegroundColor Yellow
        git pull --rebase $REMOTE $branch
        git push $REMOTE HEAD
        if ($LASTEXITCODE -ne 0) { throw "git push 仍失敗，請手動處理衝突後再重試。" }
    }
}

function Test-RemoteTagExists([string]$tag) {
    $out = git ls-remote --tags $REMOTE "refs/tags/$tag" 2>$null
    return (-not [string]::IsNullOrWhiteSpace($out))
}

function Get-RemoteLatestVersion {
    # 直接用遠端 tags（不依賴 GitHub API / 不需要 Release）
    # 回傳 semver（不含 v），例如 1.0.2
    $lines = git ls-remote --tags $REMOTE 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) { return $null }

    $tags = @()
    foreach ($l in $lines) {
        if ($l -match "refs/tags/(v?\d+\.\d+\.\d+)$") {
            $t = $Matches[1]
            $tags += $t.Trim()
        }
    }
    if ($tags.Count -eq 0) { return $null }

    $vers = $tags | ForEach-Object { $_.TrimStart("v") } | Where-Object { Validate-SemVer $_ }
    if ($vers.Count -eq 0) { return $null }

    # PowerShell 以字串 sort 會錯，改用三段數字排序
    $sorted = $vers | Sort-Object `
        @{ Expression = { [int]($_.Split('.')[0]) } }, `
        @{ Expression = { [int]($_.Split('.')[1]) } }, `
        @{ Expression = { [int]($_.Split('.')[2]) } }

    return $sorted[-1]
}

function Get-LocalLatestVersion {
    # 讀本地 tags（需先 git fetch --tags）
    # 回傳 semver（不含 v），例如 1.0.2
    $lines = @(git tag 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $lines -or $lines.Count -eq 0) { return $null }

    $tags = @()
    foreach ($t in $lines) {
        if ($t -match "^(v?\d+\.\d+\.\d+)$") { $tags += $Matches[1] }
    }
    if ($tags.Count -eq 0) { return $null }

    $vers = $tags | ForEach-Object { $_.TrimStart("v") } | Where-Object { Validate-SemVer $_ }
    if ($vers.Count -eq 0) { return $null }

    $sorted = $vers | Sort-Object `
        @{ Expression = { [int]($_.Split('.')[0]) } }, `
        @{ Expression = { [int]($_.Split('.')[1]) } }, `
        @{ Expression = { [int]($_.Split('.')[2]) } }

    return $sorted[-1]
}

function Update-ManifestVersion([string]$path, [string]$next) {
    if (-not (Test-Path $path)) { return }

    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json

        $props = $obj.PSObject.Properties.Name
        if ($props -contains "version") {
            $obj.version = $next
        }

        $obj | ConvertTo-Json -Depth 50 | Set-Content $path -Encoding UTF8
    } catch {
        Write-Host "警告：更新 $path 版本失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Ensure-FileExists([string]$path, [string]$msg) {
    if (-not (Test-Path $path)) { throw $msg }
}

function Try-Upload-GitHubRelease([string]$tag, [string]$zipPath) {
    # 需要 gh CLI
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Host "找不到 gh CLI，已跳過自動上傳。你可以自行到 GitHub Release 上傳資產。" -ForegroundColor Yellow
        return
    }

    Ensure-FileExists $zipPath "找不到要上傳的 zip：$zipPath"

    # 建立或更新 Release，再上傳資產（同名會覆蓋）
    $title = $tag
    $notes = "Release $tag"
    try {
        gh release view $tag --repo "$GITHUB_OWNER/$GITHUB_REPO" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Release 已存在，更新資產..." -ForegroundColor Cyan
            gh release upload $tag $zipPath --clobber --repo "$GITHUB_OWNER/$GITHUB_REPO"
        } else {
            Write-Host "建立 Release..." -ForegroundColor Cyan
            gh release create $tag $zipPath -t $title -n $notes --repo "$GITHUB_OWNER/$GITHUB_REPO"
        }
    } catch {
        Write-Host "gh release 操作失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ================== 主流程 ==================

Ensure-GitRepo
Ensure-Remote

# （A）先看工作目錄是否有變動：如果只有允許清單內，提供自動 commit
$changed = Get-ChangedFiles
if ($changed.Count -gt 0) {
    $illegal = @($changed | Where-Object { $ALLOWED_AUTO_COMMIT -notcontains $_ })
    if ($illegal.Count -gt 0) {
        Write-Host "錯誤：偵測到非允許自動 commit 的變動，為了安全已中止：" -ForegroundColor Red
        $illegal | ForEach-Object { Write-Host " - $_" }
        throw "請先手動 commit/還原上述檔案後再發佈。"
    }

    AutoCommit-IfAllowed `
      -reason "偵測到目前工作目錄有變動（允許清單內），可先自動 commit 後再繼續發佈：" `
      -commitMessage "chore: update release script / version files"
}

# 讀最新版本（tag）
try { git fetch $REMOTE --tags 2>$null | Out-Null } catch {}
$LATEST = Get-LocalLatestVersion
if (-not $LATEST) { $LATEST = Get-RemoteLatestVersion }

Write-Host "GitHub 最新版本：" -NoNewline
if ($LATEST) { Write-Host $LATEST -ForegroundColor Cyan }
else { Write-Host "（尚無 tag 或取得失敗）" -ForegroundColor Yellow }

# 詢問新版本
do {
    $NEXT = Read-Host "請輸入要發佈的新版本號 (x.y.z)"
    if ($NEXT.StartsWith("v")) { $NEXT = $NEXT.Substring(1) }
    if (-not (Validate-SemVer $NEXT)) {
        Write-Host "錯誤：版本格式錯誤，請使用 x.y.z" -ForegroundColor Red
        $NEXT = $null
    }
} until ($NEXT)

Write-Host "即將發佈版本：$NEXT" -ForegroundColor Cyan

$TAG = "v$NEXT"

# 避免重複 tag
if (Test-RemoteTagExists $TAG) {
    throw "錯誤：遠端已存在 tag $TAG，請改用更高版本號。"
}

# ★ 產物改成 FH5Bot-<ver>.zip，避免你搞混
$DIST_ZIP = Join-Path $SRC ("FH5Bot-" + $NEXT + ".zip")

# 寫入版本
Write-Host "[1/8] 更新版本檔..."
$NEXT | Set-Content "version.txt" -Encoding UTF8
@{
    version = $NEXT
    source  = "manual"
    tag     = $TAG
    builtAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json -Depth 4 | Set-Content "version.json" -Encoding UTF8
Update-ManifestVersion -path ".\manifest.json" -next $NEXT

# (B) 更新版本檔後：互動式自動 commit（只會包含版本檔/manifest）
AutoCommit-IfAllowed `
  -reason "版本檔已更新，建議先 commit 再打 tag/發佈：" `
  -commitMessage "chore: release $TAG"

# 打 tag（本地）
Write-Host "[2/8] 建立 tag..."
git tag $TAG
if ($LASTEXITCODE -ne 0) { throw "建立 tag 失敗：$TAG" }

# 推送 commit
Write-Host "[3/8] 推送 commit..."
git push $REMOTE HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Host "偵測到遠端比本機新，嘗試 pull --rebase 後再推一次..." -ForegroundColor Yellow
    $branch = (git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "master" }
    git pull --rebase $REMOTE $branch
    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) { throw "推送 commit 失敗，請手動處理衝突後重試。" }
}

# 推送 tag
Write-Host "[4/8] 推送 tag..."
git push $REMOTE $TAG
if ($LASTEXITCODE -ne 0) { throw "推送 tag 失敗：$TAG" }

# --------- 以下為打包流程（保持你原本邏輯） ---------
# 你原本的 build_app.ps1 這裡開始就是「compile / 組 app_release / 複製資源 / 打包 zip」等段落
# 我保留你上傳版本的既有流程，僅在最後上傳 release 時用 $TAG / $DIST_ZIP

# 路徑準備
$APP_RELEASE = Join-Path $SRC "app_release"
if (Test-Path $APP_RELEASE) { Remove-Item $APP_RELEASE -Recurse -Force }
New-Item -ItemType Directory -Path $APP_RELEASE | Out-Null

New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "bot") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $APP_RELEASE "assets") | Out-Null

# 你的實際專案：把 .py 編譯成 .pyc 並複製到 app_release
# 這段假設你目前工作目錄就是 FH5Bot_src，且有 Launcher.py、bot\*.py、assets\*
Write-Host "[5/8] 編譯 .py -> .pyc..."
$PY = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $PY) { throw "找不到 python，請先安裝/設定 PATH" }

python -m compileall . | Out-Null

# 複製 Launcher.pyc（從 __pycache__ 取出）
Write-Host "[6/8] 複製 .pyc..."
$LAUNCHER_PYCACHE = Join-Path $SRC "__pycache__"
$BOT_PYCACHE      = Join-Path (Join-Path $SRC "bot") "__pycache__"

Ensure-FileExists $LAUNCHER_PYCACHE "找不到 __pycache__：$LAUNCHER_PYCACHE（請確認 Launcher.py 有被 compileall 編譯）"
Ensure-FileExists $BOT_PYCACHE      "找不到 bot\__pycache__：$BOT_PYCACHE（請確認 bot 模組有被 compileall 編譯）"

# Launcher
$launcherPyc = Get-ChildItem "$LAUNCHER_PYCACHE\Launcher*.pyc" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $launcherPyc) { throw "找不到 Launcher 的 .pyc（__pycache__\Launcher*.pyc）" }
Copy-Item $launcherPyc.FullName (Join-Path $APP_RELEASE "Launcher.pyc") -Force

# bot\*.pyc（改名去掉 cpython-311 後綴）
Get-ChildItem "$BOT_PYCACHE\*.pyc" | ForEach-Object {
    $name = ($_.BaseName -replace '\.cpython-\d+$','') + ".pyc"
    Copy-Item $_.FullName (Join-Path (Join-Path $APP_RELEASE "bot") $name) -Force
}

# 資源
Write-Host "[7/8] 複製資源..."
Ensure-FileExists ".\assets" "找不到 .\assets，請確認資源資料夾存在。"
Copy-Item ".\assets\*" (Join-Path $APP_RELEASE "assets") -Recurse -Force
if (Test-Path ".\default_config.json") { Copy-Item ".\default_config.json" $APP_RELEASE -Force }
if (Test-Path ".\manifest.json")       { Copy-Item ".\manifest.json"       $APP_RELEASE -Force }
if (Test-Path ".\version.txt")         { Copy-Item ".\version.txt"         $APP_RELEASE -Force }
if (Test-Path ".\version.json")        { Copy-Item ".\version.json"        $APP_RELEASE -Force }

# 打包 zip（只打包 app_release 的內容，確保 GitHub 也一致）
Write-Host "[8/8] 打包 zip..."
if (Test-Path $DIST_ZIP) { Remove-Item $DIST_ZIP -Force }

Compress-Archive -Path (Join-Path $APP_RELEASE "*") -DestinationPath $DIST_ZIP -Force

Write-Host "=== 本機打包完成 ===" -ForegroundColor Green
Write-Host "產出檔案：" $DIST_ZIP
Write-Host "GitHub tag：" $TAG

# 是否要自動建立/更新 GitHub Release 並上傳資產
$doUpload = Confirm-YesNo "是否要建立/更新 GitHub Release 並上傳這包 zip？(Y/N)"
if ($doUpload) {
    Try-Upload-GitHubRelease -tag $TAG -zipPath $DIST_ZIP
    Write-Host "=== GitHub Release 處理完成 ===" -ForegroundColor Green
} else {
    Write-Host "已跳過自動上傳。你要上傳到 GitHub 的正確檔案就是這個：" -ForegroundColor Yellow
    Write-Host "  $DIST_ZIP"
}
