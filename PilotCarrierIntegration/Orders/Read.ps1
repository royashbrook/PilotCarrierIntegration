# What to try this run: the poll window, the orders Pilot returns for it, the reference lists, then each
# open order through Translate.ps1. Orders already staged or skipped are known from Cache.ps1.

function New-PilotReferenceIndex {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Records, [Parameter(Mandatory)][string]$Key)
  $index = @{}
  foreach ($record in @($Records)) {
    $value = $record.$Key
    if ($null -eq $value -or [string]$value -eq '') { continue }
    $id = [string]$value
    if ($index.ContainsKey($id)) { throw "Pilot reference endpoint returned duplicate $Key $id." }
    $index[$id] = $record
  }
  $index
}

# The lists only fill in names and addresses, and they rarely change. Each is kept in the cache folder
# and read from Pilot again only when an order names an id the kept copy lacks, or when the kept copy
# is older than keep_days. Without a cache folder (a dry run, a test) the lists are read every time.
function Get-PilotReferenceData {
  param($Session, [AllowEmptyCollection()]$Records = @(), [string]$CacheDir, [int]$KeepDays = 7)
  $data = [ordered]@{}
  foreach ($list in $script:PilotReferenceLists) {
    $path = if ($CacheDir) { Join-Path $CacheDir "reference-$($list.name).json" }
    $kept = if ($path -and (Test-Path -LiteralPath $path)) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    # a list kept by 0.5.0 is a bare array with no read_at: treat it as stale and read it again
    $readAt = if ($kept -isnot [array]) { $kept.read_at }
    $rows = if ($readAt -and ([datetime]$readAt).ToUniversalTime() -gt [datetime]::UtcNow.AddDays(-$KeepDays)) { @($kept.rows) } else { $null }
    $index = if ($null -ne $rows) { New-PilotReferenceIndex $rows $list.key } else { $null }
    $needed = @($Records.dispatchOrderItems.($list.id) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($null -eq $index -or @($needed | Where-Object { -not $index.ContainsKey($_) }).Count) {
      $rows = @(& $list.read -Session $Session)
      $index = New-PilotReferenceIndex $rows $list.key
      if ($path) {
        $null = New-Item -ItemType Directory -Force $CacheDir
        [pscustomobject]@{ read_at = [datetime]::UtcNow.ToString('o'); rows = $rows } | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $path
        Write-Log "Pilot  : $($list.name) list read, $($rows.Count) kept"
      }
    }
    $data["$($list.name)s"] = $index
  }
  [pscustomobject]$data
}

function Get-PilotIncludeStatuses($Cfg) {
  @(@(if ($Cfg.poll.include_statuses) { $Cfg.poll.include_statuses } else { 2 }) | ForEach-Object { [int]$_ })
}

function Get-PilotOrderWindow {
  param($Cfg, [int]$WindowDays = 0, [datetime]$Now = (Get-Date))
  if (-not $WindowDays) { $WindowDays = if ($Cfg.poll.window_days) { [int]$Cfg.poll.window_days } else { 30 } }
  if ($WindowDays -lt 2) { throw "A $WindowDays-day Pilot window can drop loads that cross the boundary. Use 2 or more." }
  $mode = if ($Cfg.poll.start_from) { [string]$Cfg.poll.start_from } else { 'today' }
  if ($mode -notin @('today', 'now')) { throw "Unsupported poll.start_from '$mode'. Use today or now." }
  $start = $(if ($mode -eq 'now') { $Now } else { $Now.Date }).AddDays(-[int]$Cfg.poll.lookback_days)
  $end = $start.AddDays($WindowDays)
  $queryEnd = $end
  # The client discards clock time; cover the tail day before applying exact bounds locally.
  if ($mode -eq 'now' -and $end.TimeOfDay -ne [TimeSpan]::Zero) { $queryEnd = $end.Date.AddDays(1) }
  if ($mode -eq 'now' -and ($queryEnd.Date - $start.Date).Days -gt 30) { throw 'Exact poll window exceeds the 30-day Pilot date query. Reduce poll.window_days.' }
  [pscustomobject]@{ start = $start; end = $end; queryStart = $start.Date; queryEnd = $queryEnd; exact = $mode -eq 'now' }
}

function Select-PilotOrdersToProcess {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Records, $Cfg)
  $include = Get-PilotIncludeStatuses $Cfg
  $window = Get-PilotOrderWindow $Cfg
  @($Records) | Where-Object { -not (Get-PilotOrderSkipReason $_ $include $window) }
}

function Receive-PilotOrders {
  param($Cfg, $Session, [int]$WindowDays = 0)

  $window = Get-PilotOrderWindow $Cfg $WindowDays
  if ($window.exact) { Write-Log "Pilot window: $($window.start.ToString('o')) <= scheduled start < $($window.end.ToString('o'))" }
  $cacheDir = Get-PilotOrderCacheDir $Cfg
  # an order file is kept keep_days (7 by default) after its last update, read from the file itself:
  # Pilot sends loads a few days out, so an order that old is staged, entered by hand, or gone. one
  # read again later is only checked again
  if ($cacheDir -and (Test-Path -LiteralPath $cacheDir)) {
    $cutoff = [datetime]::UtcNow.AddDays(-(Get-PilotKeepDays $Cfg))
    foreach ($file in @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -File | Where-Object Name -notlike 'reference-*')) {
      $at = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).updated_at
      if (-not $at -or ([datetime]$at).ToUniversalTime() -lt $cutoff) { Remove-Item -LiteralPath $file.FullName }
    }
  }

  $records = @(Get-PilotOrder -Session $Session -StartDate $window.queryStart -EndDate $window.queryEnd)
  # Pilot's read has no status filter (probed 2026-09-29), so every check that needs only the order
  # itself runs here, before anything else is read
  $include = Get-PilotIncludeStatuses $Cfg
  $open = [Collections.Generic.List[object]]::new()
  $staged = 0; $skipped = 0
  foreach ($record in $records) {
    if ((Get-PilotOrderCache $cacheDir $record.dispatchOrderId).state -eq 'staged') { $staged++; continue }
    $reason = Get-PilotOrderSkipReason $record $include $window
    if ($reason) { Skip-PilotOrder $cacheDir $record.dispatchOrderId $reason $record; $skipped++; continue }
    $open.Add($record)
  }
  Write-Log "Pilot  : $($records.Count) orders read, $staged already staged, $skipped skipped, $($open.Count) to stage"
  if (-not $open.Count) { return }
  $references = Get-PilotReferenceData $Session $open $cacheDir (Get-PilotKeepDays $Cfg)

  foreach ($record in $open) {
    try {
      ConvertFrom-PilotOrder $record -Cfg $Cfg -References $references
    } catch {
      Skip-PilotOrder $cacheDir $record.dispatchOrderId $_.Exception.Message $record
    }
  }
}
