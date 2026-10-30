# The order feed as DataAgent runs it, every poll (New-PilotCarrierOrderConfig in the psm1 wires the three):
#
#   src  Read-PilotCarrierOrders  read the poll window from Pilot, skip what is not ready or already
#                                 staged, translate the rest (Read.ps1, Map.ps1, Translate.ps1)
#   fmt  Save-PilotOrderPlan      keep the translated orders, types intact, for the destination
#   dst  Send-PilotOrderPlan      stage each order in TMW DataExchange at EDI state 10 (Tmw.ps1), keep
#                                 each result in the order cache (Read.ps1); dry_run validates and rolls back

# the TMW writer reads settings through PSObject.Properties, so the order path works on the JSON object shape
function ConvertTo-PilotOrderCfg([hashtable]$Settings) { $Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

# DataAgent source: Pilot orders ready to stage, translated
function Read-PilotCarrierOrders {
  param([hashtable]$Options)
  $session = New-PilotCarrierSession $Options.Settings.pilot
  $orders = @(Receive-PilotOrders (ConvertTo-PilotOrderCfg $Options.Settings) $session)
  Write-Log "Orders : $($orders.Count) from Pilot to stage"
  $orders
}

# DataAgent formatter: keep the translated orders, types intact, for the destination
function Save-PilotOrderPlan {
  param($Data, [hashtable]$Options)
  $null = New-Item -ItemType Directory -Force (Split-Path $Options.Path)
  @($Data) | Export-Clixml -LiteralPath $Options.Path -Depth 20
}

# DataAgent destination: stage each order in TMW; dry_run validates and rolls back
function Send-PilotOrderPlan {
  param([string]$Path, [hashtable]$Options)
  $orders = @(Import-Clixml -LiteralPath $Path)
  $cfg = ConvertTo-PilotOrderCfg $Options.Settings
  $commit = -not $Options.Settings.dry_run
  Write-Log "Stage  : $($orders.Count) order(s), $(if ($commit) { 'commit' } else { 'validate only' })"
  $results = @(Write-TmwOrders -Orders $orders -Cfg $cfg -ConnectionString $cfg.tmw.connection_string -Commit:$commit)
  $byId = @{}; foreach ($order in $orders) { $byId[[string]$order.pilotOrderId] = $order }
  foreach ($result in $results) {
    # only a CREATED order was built from this record; EXISTS leaves TMW as it was, from an earlier one
    $source = if ($result.action -eq 'CREATED') { $byId[[string]$result.pilot_order_id] }
    if ($result.ok -and $commit) { Set-PilotOrderCache (Get-PilotOrderCacheDir $cfg) $result.pilot_order_id 'staged' $result.order_number $source }
    if ($result.ok) { Write-Log ("{0,-7}: {1}: TMW order {2}, state {3}" -f $result.action, $result.pilot_order_id, $result.order_number, $result.edistate) }
    else { Write-Log ("Failed : {0} after {1} attempt(s): {2}" -f $result.pilot_order_id, $result.attempts, $result.error) }
  }
  $failed = @($results | Where-Object { -not $_.ok })
  if ($failed.Count) { throw "$($failed.Count) Pilot order(s) failed after retries; the next run tries again." }
}
