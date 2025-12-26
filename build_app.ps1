# =====================================================
# FH5Bot 發佈腳本（PowerShell 7+）
# 修正：最新版本顯示 0 → 改成本地 tags 優先
# =====================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

# ===== 強制 PowerShell 7+ =====
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "錯誤：請使用 PowerShell 7+（pwsh）執行此腳本。" -ForegroundColor Red
    Write-Host "範例：pwsh -ExecutionPolicy Bypass -File .\build_app.ps1" -ForegroundColor Yellow
    exit 1
}

# ---------- 設定 ----------
$GITHUB_OWNER = "future830759"
$GITHUB_REPO  = "FH5Bot"

# 允許自動 commit 的檔案（版本檔 + 發佈腳本本身）
$ALLOWED_AUTO_COMMIT = @(
    "version.txt",
    "version.json",
    "manifest.json",
    "build_app.ps1"
)

function Get-DefaultRemoteName {
    $remotes = @(git remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remotes -or $remotes.Count -eq 0) { return "origin" }
    if ($remotes -contains "origin") { return "origin" }
    return $remotes[0]
}

$REMOTE = Get-DefaultRemoteName

# ---------- helpers ----------
function Validate-SemVer([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    return ($v -match '^\d+\.\d+\.\d+$')
}

function Normalize-Version([string]$tagOrVer) {
    if ([string]::IsNullOrWhiteSpace($tagOrVer)) { return $null }
    $v = $tagOrVer.Trim()
    if ($v.StartsWith("v")) { $v = $v.Substring(1) }
    if (Validate-SemVer $v) { return $v }
    return $null
}

function Sort-SemVers([string[]]$vers) {
    return $vers | Sort-Object `
        @{ Expression = { [int]($_.Split('.')[0]) } }, `
        @{ Expression = { [int]($_.Split('.')[1]) } }, `
        @{ Expression = { [int]($_.Split('.')[2]) } }
}

function Ensure-GitRepo {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "目前資料夾不是 Git repo（找不到 .git）。請切到專案根目錄再執行。"
    }
}

function Ensure-Remote {
    $u = git remote get-url $REMOTE 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($u)) {
        throw "找不到 remote '$REMOTE'。請先設定 remote（建議叫 origin）。"
    }
}

function Get-ChangedFiles {
    $lines = git status --porcelain 2>$null
    if (-not $lines) { return @() }

    $files = @()
    foreach ($l in $lines) {
        if ($l.Length -lt 4) { continue }
        $files += $l.Substring(3).Trim()
    }
    return $files
}

function Confirm-YesNo([string]$prompt) {
    while ($true) {
        $ans = Read-Host $prompt
        if ($null -eq $ans) { continue }
        $ans = $ans.Trim().ToUpperInvariant()
        if ($ans -eq "Y") { return $true }
        if ($ans -eq "N") { return $false }
        Write-Host "請輸入 Y 或 N" -ForegroundColor Yellow
    }
}

function Git-PushSafe {
    $branch = (git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "master" }

    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "偵測到遠端比本機新，嘗試 pull --rebase 後再推一次..." -ForegroundColor Yellow
        git pull --rebase $REMOTE $branch
        git push $REMOTE HEAD
        if ($LASTEXITCODE -ne 0) { throw "git push 失敗（rebase 後仍失敗），請手動處理衝突後重試。" }
    }
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
    if (-not $doIt) { throw "你選擇不自動 commit。請手動處理變動後再重新執行。" }

    foreach ($f in $ALLOWED_AUTO_COMMIT) {
        if (Test-Path $f) { git add $f 2>$null }
    }
    git add -u 2>$null

    $staged = git diff --cached --name-only 2>$null
    if (-not $staged) {
        Write-Host "沒有 staged 變更，略過 commit。" -ForegroundColor Yellow
        return
    }

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗。" }

    Git-PushSafe
}

function Get-LocalLatestVersion {
    $tags = @(git tag 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $tags -or $tags.Count -eq 0) { return $null }

    $vers = @()
    foreach ($t in $tags) {
        $v = Normalize-Version $t
        if ($v) { $vers += $v }
    }
    if ($vers.Count -eq 0) { return $null }

    (Sort-SemVers $vers)[-1]
}

function Get-RemoteLatestVersion {
    $lines = git ls-remote --tags $REMOTE 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) { return $null }

    $vers = @()
    foreach ($l in $lines) {
        if ($l -match "refs/tags/(v?\d+\.\d+\.\d+)$") {
            $v = Normalize-Version $Matches[1]
            if ($v) { $vers += $v }
        }
    }
    if ($vers.Count -eq 0) { return $null }

    (Sort-SemVers $vers)[-1]
}

function Test-RemoteTagExists([string]$tag) {
    $out = git ls-remote --tags $REMOTE "refs/tags/$tag" 2>$null
    return (-not [string]::IsNullOrWhiteSpace($out))
}

function Update-ManifestVersion([string]$path, [string]$next) {
    if (-not (Test-Path $path)) { return }

    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json

        $props = $obj.PSObject.Properties.Name
        if ($props -contains "version") {
            $obj.version = $next
        } elseif ($props -contains "Version") {
            $obj.Version = $next
        } else {
            Write-Host "警告：manifest.json 找不到 version/Version 欄位，已跳過更新（不影響打包）。" -ForegroundColor Yellow
            return
        }

        $obj | ConvertTo-Json -Depth 50 | Set-Content $path -Encoding UTF8
    } catch {
        Write-Host "警告：更新 manifest.json 失敗，已跳過（不影響打包）。原因：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Ensure-FileExists([string]$path, [string]$msgIfMissing) {
    if (-not (Test-Path $path)) { throw $msgIfMissing }
}

function Try-Upload-GitHubRelease([string]$tag, [string]$zipPath) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Host "警告：找不到 gh（GitHub CLI），已跳過自動上傳。請手動上傳：" -ForegroundColor Yellow
        Write-Host "  $zipPath"
        return
    }

    Ensure-FileExists $zipPath "找不到要上傳的 zip：$zipPath"

    $title = "FH5Bot $tag"
    $notes = "Auto release for $tag"

    gh release view $tag --repo "$GITHUB_OWNER/$GITHUB_REPO" *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "建立 GitHub Release：$tag 並上傳資產..." -ForegroundColor Cyan
        gh release create $tag $zipPath --title $title --notes $notes --repo "$GITHUB_OWNER/$GITHUB_REPO"
    } else {
        Write-Host "Release 已存在：$tag，更新/覆蓋資產..." -ForegroundColor Cyan
        gh release upload $tag $zipPath --clobber --repo "$GITHUB_OWNER/$GITHUB_REPO"
    }
}

# ---------- main ----------
Ensure-GitRepo
Ensure-Remote

# (A) 若有變動：允許版本檔/build_app.ps1 → 互動式自動 commit
AutoCommit-IfAllowed -reason "偵測到目前工作目錄有變動（允許清單內），可先自動 commit 後再繼續發佈：" `
                     -commitMessage "chore: update release script / version files"

# ★ 關鍵：先 fetch tags，再「本地 tags 優先」取最新版本
try { git fetch $REMOTE --tags 2>$null | Out-Null } catch {}

$LATEST = Get-LocalLatestVersion
if (-not $LATEST) { $LATEST = Get-RemoteLatestVersion }

Write-Host "GitHub 最新版本：" -NoNewline
if ($LATEST) { Write-Host $LATEST -ForegroundColor Cyan }
else { Write-Host "（尚無 tag 或取得失敗）" -ForegroundColor Yellow }

# 詢問新版本
do {
    $NEXT = (Read-Host "請輸入要發佈的新版本號 (x.y.z)").Trim()
    if (-not (Validate-SemVer $NEXT)) {
        Write-Host "錯誤：版本格式錯誤，請使用 x.y.z" -ForegroundColor Red
        $NEXT = $null
    }
} until ($NEXT)

Write-Host "即將發佈版本：" -NoNewline
Write-Host $NEXT -ForegroundColor Green

$TAG = "v$NEXT"

# 避免 tag 重複
if (Test-RemoteTagExists $TAG) {
    throw "遠端已存在 tag：$TAG。請換一個新版本號（例如 1.0.1）。"
}

# 路徑
$SRC = Get-Location
$APP_RELEASE = Join-Path $SRC "app_release"
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

# (B) 更新版本檔後：互動式自動 commit
AutoCommit-IfAllowed -reason "偵測到版本檔變動（準備發佈），可自動 commit：" `
                     -commitMessage ("chore: release " + $TAG)

# 建立 tag & push tag（用 REMOTE）
git tag $TAG
if ($LASTEXITCODE -ne 0) { throw "建立 tag 失敗：$TAG" }

git push $REMOTE $TAG
if ($LASTEXITCODE -ne 0) { throw "推送 tag 失敗：$TAG" }

# 清理舊檔
Write-Host "[2/8] 清理舊檔..."
Remove-Item $APP_RELEASE -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $DIST_ZIP -Force -ErrorAction SilentlyContinue

# compile
Write-Host "[3/8] compileall..."
python -m compileall . | Out-Null

# 建立 app_release
Write-Host "[4/8] 建立 app_release..."
New-Item -ItemType Directory -Force `
  "$APP_RELEASE\bot",
  "$APP_RELEASE\assets" | Out-Null

# __main__.pyc（從 __pycache__ 找最新 main.cpython-*.pyc）
Write-Host "[5/8] 準備 __main__.pyc..."
$MAIN_PYC = Get-ChildItem "__pycache__\main.cpython-*.pyc" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $MAIN_PYC) { throw "找不到 main.py 編譯後的 pyc（請確認 main.py 存在且 compileall 成功）" }
Copy-Item $MAIN_PYC.FullName "$APP_RELEASE\__main__.pyc" -Force

# bot 模組 pyc
Write-Host "[6/8] 準備 bot 模組..."
New-Item -ItemType File -Force "$APP_RELEASE\bot\__init__.py" | Out-Null
$BOT_PYCACHE = Join-Path $SRC "bot\__pycache__"
if (-not (Test-Path $BOT_PYCACHE)) { throw "找不到 bot 的 __pycache__：$BOT_PYCACHE（請確認 bot 模組有被 compileall 編譯）" }

Get-ChildItem "$BOT_PYCACHE\*.pyc" | ForEach-Object {
    $name = ($_.BaseName -replace '\.cpython-\d+$','') + ".pyc"
    Copy-Item $_.FullName (Join-Path "$APP_RELEASE\bot" $name) -Force
}

# 資源
Write-Host "[7/8] 複製資源..."
Ensure-FileExists ".\assets" "找不到 .\assets，請確認資源資料夾存在。"
Copy-Item ".\assets\*" "$APP_RELEASE\assets" -Recurse -Force
if (Test-Path ".\default_config.json") { Copy-Item ".\default_config.json" "$APP_RELEASE\" -Force }
if (Test-Path ".\manifest.json") { Copy-Item ".\manifest.json" "$APP_RELEASE\" -Force }
if (Test-Path ".\version.txt") { Copy-Item ".\version.txt" "$APP_RELEASE\" -Force }
if (Test-Path ".\version.json") { Copy-Item ".\version.json" "$APP_RELEASE\" -Force }

# 打包 zip
Write-Host "[8/8] 打包 zip..."
Compress-Archive -Force -Path "$APP_RELEASE\*" -DestinationPath $DIST_ZIP

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
