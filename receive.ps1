# why a Pilot order is not staged this run, or nothing when it is a good load: a status in
# poll.include_statuses (Scheduled, 2, by default), a delivery window that ends after it starts, and at
# least one active item, every one with gallons. an order that is not good yet stays in Pilot and is read
# again next run
function Get-PilotOrderSkipReason {
  param([Parameter(Mandatory)]$Record, [int[]]$Include = @(2))
  if (-not $Record.dispatchOrderId) { return 'no dispatchOrderId' }
  if ([int]$Record.dispatchOrderStatusTypeId -notin $Include) { return "status $($Record.dispatchOrderStatusTypeId) $($Record.dispatchOrderStatusTypeName)".Trim() }
  if (-not $Record.deliveryWindowStartDateTime -or -not $Record.deliveryWindowEndDateTime) { return 'no delivery window' }
  if ([datetime]$Record.deliveryWindowEndDateTime -le [datetime]$Record.deliveryWindowStartDateTime) { return 'delivery window ends before it starts' }
  $items = @($Record.dispatchOrderItems | Where-Object { -not $_.isDeleted })
  if (-not $items.Count) { return 'no active items' }
  $empty = @($items | Where-Object { $null -eq $_.gallons -or [decimal]$_.gallons -le 0 })
  if ($empty.Count) { return "no gallons on item $(@($empty.dispatchOrderItemId) -join ', ')" }
}

function Get-PilotIncludeStatuses($Cfg) {
  @(@(if ($Cfg.poll.include_statuses) { $Cfg.poll.include_statuses } else { 2 }) | ForEach-Object { [int]$_ })
}

function Select-PilotOrdersToProcess {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Records, $Cfg)
  $include = Get-PilotIncludeStatuses $Cfg
  @($Records) | Where-Object { -not (Get-PilotOrderSkipReason $_ $include) }
}

# the order cache: one file per Pilot order in the job's cache folder (settings "cache", default "cache"),
# the same folder and naming the other order feeds use. staged orders are passed over before anything
# else; a skipped order keeps its reason, logged again only when the reason changes. a dry run keeps none
function Get-PilotOrderCacheDir($Cfg) {
  if ($Cfg.dry_run -or -not $Cfg.directory) { return $null }
  Join-Path $Cfg.directory $(if ($Cfg.cache) { [string]$Cfg.cache } else { 'cache' })
}

function Get-PilotOrderCache([string]$CacheDir, $Id) {
  if (-not $CacheDir) { return $null }
  $path = Join-Path $CacheDir "$Id.json"
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

function Set-PilotOrderCache([string]$CacheDir, $Id, [string]$State, [string]$Detail) {
  if (-not $CacheDir) { return }
  $null = New-Item -ItemType Directory -Force $CacheDir
  [pscustomobject][ordered]@{
    dispatch_order_id = [string]$Id; state = $State
    reason = if ($State -eq 'skipped') { $Detail } else { $null }
    tmw_order = if ($State -eq 'staged') { $Detail } else { $null }
    updated_at = [datetime]::UtcNow.ToString('o')
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $CacheDir "$Id.json")
}

# log a skip only when it is new or its reason changed, so a waiting order is one line, not one a run
function Skip-PilotOrder([string]$CacheDir, $Id, [string]$Reason) {
  $cached = Get-PilotOrderCache $CacheDir $Id
  if ($cached.state -eq 'skipped' -and $cached.reason -eq $Reason) { return }
  Write-Log "Skipped: $Id, $Reason"
  Set-PilotOrderCache $CacheDir $Id 'skipped' $Reason
}

function Receive-PilotOrders {
  param($Cfg, $Session, [int]$WindowDays = 0)

  if (-not $WindowDays) {
    $WindowDays = if ($Cfg.poll.window_days) { [int]$Cfg.poll.window_days } else { 30 }
  }
  if ($WindowDays -lt 2) {
    throw "A $WindowDays-day Pilot window can drop loads that cross the boundary. Use 2 or more."
  }
  $cacheDir = Get-PilotOrderCacheDir $Cfg
  # an order file untouched for two windows cannot come back from Pilot's read
  if ($cacheDir -and (Test-Path -LiteralPath $cacheDir)) {
    Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -File | Where-Object {
      $_.Name -notlike 'reference-*' -and $_.LastWriteTime -lt (Get-Date).AddDays(-2 * $WindowDays)
    } | Remove-Item
  }

  $start = [datetime]::Today
  $records = @(Get-PilotOrder -Session $Session -StartDate $start -EndDate $start.AddDays($WindowDays))
  # Pilot's read has no status filter (probed 2026-09-29), so every check that needs only the order
  # itself runs here, before anything else is read
  $include = Get-PilotIncludeStatuses $Cfg
  $open = [Collections.Generic.List[object]]::new()
  $staged = 0; $skipped = 0
  foreach ($record in $records) {
    if ((Get-PilotOrderCache $cacheDir $record.dispatchOrderId).state -eq 'staged') { $staged++; continue }
    $reason = Get-PilotOrderSkipReason $record $include
    if ($reason) { Skip-PilotOrder $cacheDir $record.dispatchOrderId $reason; $skipped++; continue }
    $open.Add($record)
  }
  Write-Log "Pilot  : $($records.Count) orders read, $staged already staged, $skipped skipped, $($open.Count) to stage"
  if (-not $open.Count) { return }
  $references = Get-PilotReferenceData $Session $open $cacheDir

  foreach ($record in $open) {
    try {
      ConvertFrom-PilotOrder $record -Cfg $Cfg -References $references
    } catch {
      Skip-PilotOrder $cacheDir $record.dispatchOrderId $_.Exception.Message
    }
  }
}
