# The order cache: one file per Pilot order in the job's cache folder (settings "cache", default "cache",
# the same folder and naming the other order feeds use), staged with its TMW order or skipped with its
# reason, kept keep_days. Read.ps1 passes over the staged and logs a skip once, Run.ps1 records each
# result. A dry run keeps none.

function Get-PilotKeepDays($Cfg) { if ($Cfg.keep_days) { [int]$Cfg.keep_days } else { 7 } }

function Get-PilotOrderCacheDir($Cfg) {
  if ($Cfg.dry_run -or -not $Cfg.directory) { return $null }
  Join-Path $Cfg.directory $(if ($Cfg.cache) { [string]$Cfg.cache } else { 'cache' })
}

function Get-PilotOrderCache([string]$CacheDir, $Id) {
  if (-not $CacheDir) { return $null }
  $path = Join-Path $CacheDir "$Id.json"
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

# a staged order keeps the Pilot record and reference rows it was staged from, written once
function Set-PilotOrderCache([string]$CacheDir, $Id, [string]$State, [string]$Detail, $Order) {
  if (-not $CacheDir) { return }
  $null = New-Item -ItemType Directory -Force $CacheDir
  $entry = [ordered]@{
    dispatch_order_id = [string]$Id; state = $State
    reason = if ($State -eq 'skipped') { $Detail } else { $null }
    tmw_order = if ($State -eq 'staged') { $Detail } else { $null }
    updated_at = [datetime]::UtcNow.ToString('o')
  }
  if ($Order) { $entry.pilot = $Order.raw; $entry.references = $Order.references }
  [pscustomobject]$entry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $CacheDir "$Id.json")
}

# log a skip only when it is new or its reason changed, so a waiting order is one line, not one a run
function Skip-PilotOrder([string]$CacheDir, $Id, [string]$Reason) {
  $cached = Get-PilotOrderCache $CacheDir $Id
  if ($cached.state -eq 'skipped' -and $cached.reason -eq $Reason) { return }
  Write-Log "Skipped: $Id, $Reason"
  Set-PilotOrderCache $CacheDir $Id 'skipped' $Reason
}
