# The order cache: one file per Pilot order in the job's cache folder (settings "cache", default "cache",
# the same folder and naming the other order feeds use), staged with its TMW order or skipped with its
# reason, kept keep_days, each with the last record Pilot sent. Read.ps1 passes over the staged (noting
# once when the record would no longer stage) and logs a skip once, Run.ps1 records each result. A dry
# run keeps none.

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

# the record as Pilot sent it, hashed, so an order that has not changed is not rewritten every run
function Get-PilotRecordHash($Record) {
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Record -Depth 20 -Compress))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

# every entry keeps the last record Pilot sent for the order, so what they sent can be shown later. an
# order created in TMW also keeps the reference rows it was built from. a staged entry's note is the
# reason the latest record would not stage today, nothing while it still would
function Set-PilotOrderCache([string]$CacheDir, $Id, [string]$State, [string]$Detail, $Record, $References, [string]$Note) {
  if (-not $CacheDir) { return }
  $null = New-Item -ItemType Directory -Force $CacheDir
  $entry = [ordered]@{
    dispatch_order_id = [string]$Id; state = $State
    reason = if ($State -eq 'skipped') { $Detail } else { $null }
    tmw_order = if ($State -eq 'staged') { $Detail } else { $null }
    note = if ($State -eq 'staged' -and $Note) { $Note } else { $null }
    updated_at = [datetime]::UtcNow.ToString('o')
    pilot = $Record
    pilot_hash = if ($Record) { Get-PilotRecordHash $Record }
  }
  if ($References) { $entry.references = $References }
  [pscustomobject]$entry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $CacheDir "$Id.json")
}

# a staged order is TMW's now. the check its latest record fails (its status moved on, Pilot changed an
# item) is logged once, when new or changed, and the entry stays staged with the record and its note. the
# entry is rewritten only when the record or the note changed, so a quiet order is not rewritten every run
function Update-PilotStagedOrder([string]$CacheDir, $Cached, $Record, [string]$Reason) {
  $changed = [string]$Cached.note -ne $Reason
  if ($changed -and $Reason) { Write-Log "Staged : $($Cached.dispatch_order_id), TMW order $($Cached.tmw_order), now $Reason" }
  if ($changed -or $Cached.pilot_hash -ne (Get-PilotRecordHash $Record)) {
    Set-PilotOrderCache $CacheDir $Cached.dispatch_order_id 'staged' $Cached.tmw_order $Record $Cached.references $Reason
  }
}

# log a skip only when it is new or its reason changed, so a waiting order is one line, not one a run.
# the entry is rewritten when the reason or the record changed. a staged entry is never replaced by a skip
function Skip-PilotOrder([string]$CacheDir, $Id, [string]$Reason, $Record) {
  $cached = Get-PilotOrderCache $CacheDir $Id
  if ($cached.state -eq 'staged') { throw "Pilot order $Id is staged in TMW (order $($cached.tmw_order)); a skip cannot replace it." }
  if ($cached.state -eq 'skipped' -and $cached.reason -eq $Reason) {
    if ($cached.pilot_hash -eq (Get-PilotRecordHash $Record)) { return }
  } else {
    Write-Log "Skipped: $Id, $Reason"
  }
  Set-PilotOrderCache $CacheDir $Id 'skipped' $Reason $Record
}
