# =====================================================
# FH5Bot 發佈腳本（PowerShell 7+）
# 修正：GitHub 最新版本顯示 0 的問題（改用本地 tags 優先）
# =====================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "錯誤：請使用 PowerShell 7+（pwsh）執行此腳本。" -ForegroundColor Red
    Write-Host "請在 Windows Terminal 或 PowerShell 7 開啟後執行：pwsh -File .\build_app.ps1" -ForegroundColor Yellow
    exit 1
}

function Get-DefaultRemoteName {
    $remotes = @(git remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remotes -or $remotes.Count -eq 0) { return "origin" }
    if ($remotes -contains "origin") { return "origin" }
    return $remotes[0]
}

$REMOTE = Get-DefaultRemoteName

function Validate-SemVer([string]$v) {
    return (-not [string]::IsNullOrWhiteSpace($v)) -and ($v -match '^\d+\.\d+\.\d+$')
}

function Ensure-GitRepo {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { throw "目前資料夾不是 Git repo（找不到 .git）。" }
}

function Ensure-Remote {
    $u = git remote get-url $REMOTE 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($u)) {
        throw "找不到 remote '$REMOTE'。請先設定 remote（建議叫 origin）。"
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
        if (-not [string]::IsNullOrWhiteSpace($path)) { $files += $path }
    }
    return $files
}

# 僅允許腳本自動 commit 的檔案（安全）
$ALLOWED_AUTO_COMMIT = @(
    "build_app.ps1",
    "version.txt",
    "version.json",
    "manifest.json",
    "default_config.json",
    "README.md",
    ".gitignore"
)

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
    if (-not $doIt) { throw "你選擇不自動 commit。請手動處理後再重跑。" }

    foreach ($f in $ALLOWED_AUTO_COMMIT) {
        if (Test-Path $f) { git add $f 2>$null }
    }
    git add -u 2>$null

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit 失敗。" }

    # push commit
    $branch = (git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "master" }

    git push $REMOTE HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "偵測到遠端比本機新，嘗試 pull --rebase 後再推一次..." -ForegroundColor Yellow
        git pull --rebase $REMOTE $branch
        git push $REMOTE HEAD
        if ($LASTEXITCODE -ne 0) { throw "git push 仍失敗，請手動處理衝突後再重試。" }
    }
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

function Get-LocalLatestVersion {
    $tags = @(git tag 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $tags -or $tags.Count -eq 0) { return $null }

    $vers = @()
    foreach ($t in $tags) {
        $v = Normalize-Version $t
        if ($v) { $vers += $v }
    }
    if ($vers.Count -eq 0) { return $null }

    $sorted = Sort-SemVers $vers
    return $sorted[-1]
}

function Get-RemoteLatestVersion {
    # fallback：遠端 tags
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

    $sorted = Sort-SemVers $vers
    return $sorted[-1]
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
        if ($obj.PSObject.Properties.Name -contains "version") {
            $obj.version = $next
        }
        $obj | ConvertTo-Json -Depth 50 | Set-Content $path -Encoding UTF8
    } catch {
        Write-Host "警告：更新 $path 版本失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ================== 主流程 ==================
Ensure-GitRepo
Ensure-Remote

# 如果工作目錄有變動（且都在允許清單內）先自動 commit
$changed = Get-ChangedFiles
if ($changed.Count -gt 0) {
    AutoCommit-IfAllowed `
        -reason "偵測到目前工作目錄有變動（允許清單內），可先自動 commit 後再繼續發佈：" `
        -commitMessage "chore: update release script / version files"
}

# ★ 關鍵：先把遠端 tags 抓回本地，然後「優先用本地 tags」算最新版本
try { git fetch $REMOTE --tags 2>$null | Out-Null } catch {}

$LATEST = Get-LocalLatestVersion
if (-not $LATEST) { $LATEST = Get-RemoteLatestVersion }

Write-Host "GitHub 最新版本：" -NoNewline
if ($LATEST) { Write-Host $LATEST -ForegroundColor Cyan }
else { Write-Host "（尚無 tag 或取得失敗）" -ForegroundColor Yellow }

# 詢問新版本
do {
    $NEXT = (Read-Host "請輸入要發佈的新版本號 (x.y.z)").Trim()
    if ($NEXT.StartsWith("v")) { $NEXT = $NEXT.Substring(1) }
    if (-not (Validate-SemVer $NEXT)) {
        Write-Host "版本格式錯誤，請輸入 x.y.z（例如 1.0.1）" -ForegroundColor Yellow
        $NEXT = ""
    }
} while ([string]::IsNullOrWhiteSpace($NEXT))

Write-Host "即將發佈版本：$NEXT" -ForegroundColor Cyan
$TAG = "v$NEXT"

if (Test-RemoteTagExists $TAG) { throw "錯誤：遠端已存在 tag $TAG，請改用更高版本號。" }

# ===== 你原本後續流程（更新版本檔 / 打包 / 上傳）可以接在這裡 =====
# 下面先提供一個最小可用流程（你若本來就有更完整的打包流程，可自行替換）

# 版本檔
$NEXT | Set-Content "version.txt" -Encoding UTF8
@{
    version = $NEXT
    tag     = $TAG
    builtAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json -Depth 4 | Set-Content "version.json" -Encoding UTF8

Update-ManifestVersion -path ".\manifest.json" -next $NEXT

# 版本檔變更（允許清單內）可自動 commit
AutoCommit-IfAllowed `
    -reason "版本檔已更新，建議先 commit 再打 tag/發佈：" `
    -commitMessage "chore: release $TAG"

# 建立 + 推送 tag
git tag $TAG
if ($LASTEXITCODE -ne 0) { throw "建立 tag 失敗：$TAG" }

git push $REMOTE $TAG
if ($LASTEXITCODE -ne 0) { throw "推送 tag 失敗：$TAG" }

Write-Host "完成：已推送 $TAG" -ForegroundColor Green
