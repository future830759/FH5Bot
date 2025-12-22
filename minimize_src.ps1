# ===== FH5Bot_src 最小化腳本（保守安全版）=====
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Remove-IfExists([string]$path) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed: $path"
    }
}

function Remove-FilesByPattern([string]$pattern, [string[]]$excludeDirs = @()) {
    $items = Get-ChildItem $root -Recurse -Force -File -ErrorAction SilentlyContinue -Filter $pattern
    foreach ($f in $items) {
        $skip = $false
        foreach ($ex in $excludeDirs) {
            if ($f.FullName -like "*\$ex\*") { $skip = $true; break }
        }
        if (-not $skip) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Removed files: $pattern"
}

Write-Host "== FH5Bot_src minimize start =="

# 0) 備份（同層）
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$parent = Split-Path $root -Parent
$dst = Join-Path $parent ("FH5Bot_src_backup_" + $stamp)
Write-Host "Backup => $dst"
Copy-Item $root $dst -Recurse -Force

# 1) Python 快取
Get-ChildItem $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq "__pycache__" } |
  ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "Removed: __pycache__"

Remove-FilesByPattern "*.pyc"
Remove-FilesByPattern "*.pyo"

# 2) 常見測試/工具快取
Remove-IfExists (Join-Path $root ".pytest_cache")
Remove-IfExists (Join-Path $root ".mypy_cache")
Remove-IfExists (Join-Path $root ".ruff_cache")
Remove-IfExists (Join-Path $root ".coverage")
Remove-IfExists (Join-Path $root ".hypothesis")
Remove-IfExists (Join-Path $root ".tox")

# 3) 建置產物（Python / PyInstaller）
Remove-IfExists (Join-Path $root "build")
Remove-IfExists (Join-Path $root "dist")
Remove-IfExists (Join-Path $root ".eggs")
Remove-IfExists (Join-Path $root "*.egg-info")  # 有些會是資料夾，下面再補一刀

Get-ChildItem $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like "*.egg-info" } |
  ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "Removed: *.egg-info"

# PyInstaller 常見產物
Get-ChildItem $root -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object {
    $_.PSIsContainer -and (
      $_.Name -in @("__pycache__", "build", "dist") -or
      $_.Name -like "*.spec.cache"
    )
  } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

# 4) 壓縮包 / 安裝包（專案裡不必留）
Remove-FilesByPattern "*.whl"
Remove-FilesByPattern "*.zip"
Remove-FilesByPattern "*.7z"
Remove-FilesByPattern "*.rar"

# 5) log / dump（常見）
Remove-FilesByPattern "*.log"
Remove-FilesByPattern "*.dmp"

# 6) 編輯器 / OS 雜項（不碰 .git）
Remove-IfExists (Join-Path $root ".vscode")
Remove-IfExists (Join-Path $root ".idea")
Remove-FilesByPattern "Thumbs.db"
Remove-FilesByPattern ".DS_Store"

# 7) 虛擬環境（若你把 venv 放在專案內，這一刀會很大）
# 如果你確定 venv 是放在專案裡才會砍；放外面就無影響
Remove-IfExists (Join-Path $root ".venv")
Remove-IfExists (Join-Path $root "venv")

Write-Host "== FH5Bot_src minimize done =="
