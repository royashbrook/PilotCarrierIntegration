# Pilot BOL completions: TMW completed freight -> one PUT /bol per order, once every line is complete.
#
# The order is decided complete from TMW alone. Every freight line carries its Pilot item id (the OID
# pil-order staged), so no Pilot read is needed first: a post Kiosks the whole order, which is why an
# order goes only when every line has its item, BOL, gallons and times. Pilot's answer says whether the
# order is Kiosked with a BOL on every item; that is the done signal, recorded in the cache.

function New-PilotBolPlan {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$TmwRows)

  $ready = [Collections.Generic.List[object]]::new()
  $deferred = [Collections.Generic.List[object]]::new()

  foreach ($tmwOrder in @($TmwRows | Group-Object tmwOrderId)) {
    $refs = @($tmwOrder.Group.pilotOrderRef | Where-Object { $_ } | Sort-Object -Unique)
    $pilotId = 0L
    $reason = if ($refs.Count -ne 1) { if ($refs.Count) { 'multiple Pilot PO references' } else { 'no Pilot PO reference' } }
      elseif (-not [long]::TryParse([string]$refs[0], [ref]$pilotId) -or $pilotId -le 0) { 'Pilot PO reference is not a positive numeric dispatchOrderId' }
    if ($reason) {
      $deferred.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; reason = $reason })
      continue
    }

    # one row per freight line, first by sequence when the query repeats one
    $rows = @(
      $tmwOrder.Group |
        Group-Object freightId |
        ForEach-Object { @($_.Group | Sort-Object freightSequence)[0] } |
        Sort-Object freightSequence, freightId
    )
    $errors = [Collections.Generic.List[string]]::new()
    $payload = [Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
      $itemId = 0L; $bol = 0L
      $missing = @(
        if (-not [long]::TryParse([string]$row.pilotOrderItemId, [ref]$itemId) -or $itemId -le 0) { 'Pilot item id (OID)' }
        if (-not [long]::TryParse([string]$row.bolNumber, [ref]$bol) -or $bol -le 0) { 'BOL' }
        if ($null -eq $row.grossGallons -or [decimal]$row.grossGallons -le 0) { 'gross gallons' }
        if ($null -eq $row.netGallons -or [decimal]$row.netGallons -le 0) { 'net gallons' }
        if (-not $row.startPullDateTime) { 'pull start' }
        if (-not $row.endPullDateTime) { 'pull end' }
        if (-not $row.dropDateTime) { 'drop time' }
      )
      if ($missing.Count) { $errors.Add("freight $($row.freightId): missing $($missing -join ', ')"); continue }
      $payload.Add([pscustomobject][ordered]@{
        grossGallons = [decimal]$row.grossGallons
        netGallons = [decimal]$row.netGallons
        billOfLadingNumber = [long]$bol
        dispatchOrderId = [long]$pilotId
        dispatchOrderItemId = [long]$itemId
        dropDateTime = ([datetime]$row.dropDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        startPullDateTime = ([datetime]$row.startPullDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        endPullDateTime = ([datetime]$row.endPullDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        railCarNumber = if ($row.railCarNumber) { [string]$row.railCarNumber } else { $null }
      })
    }
    if (-not $errors.Count -and @($payload.dispatchOrderItemId | Sort-Object -Unique).Count -ne $payload.Count) {
      $errors.Add('two freight lines carry the same Pilot item id')
    }
    if ($errors.Count) {
      $deferred.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; dispatchOrderId = [long]$pilotId; reason = ($errors -join '; ') })
      continue
    }
    $ready.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; dispatchOrderId = [long]$pilotId; payload = @($payload) })
  }

  [pscustomobject]@{ ready = @($ready); deferred = @($deferred) }
}

# one file per Pilot order in the cache folder (settings "cache", default "cache", like the other order feeds): what goes, its state,
# and Pilot's answer. an order is written there as pending before it is posted and marked done when Pilot finishes it. one done
# goes again only when what it would send changes
function Get-PilotBolHash($Payload) {
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Payload) -Depth 6 -Compress))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-PilotBolCache([string]$Folder, $DispatchOrderId) {
  $path = Join-Path $Folder "$DispatchOrderId.json"
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

# the order files, not the cursor
function Get-PilotBolCacheFiles([string]$Folder) {
  if (Test-Path -LiteralPath $Folder) { @(Get-ChildItem -LiteralPath $Folder -Filter '*.json' -File | Where-Object BaseName -match '^\d+$') }
}

# a file from before states is an order done
function Test-PilotBolPending($Cached) { $Cached -and $Cached.state -eq 'pending' }

# the TMW time the next run reads from, like gravitate's cursor, so a run missed for any length of time loses nothing. it stops at
# the oldest order still pending, so the query keeps returning that order and it goes again; an order held for missing data comes
# back when TMW changes it
function Get-PilotBolCursor([string]$Folder) {
  $path = Join-Path $Folder 'cursor.json'
  if (Test-Path -LiteralPath $path) { Format-TmwTime (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).since }
}

# TMW times have no zone and json reads them back as dates, so they are written one way, to the millisecond
function Format-TmwTime($Value) { if ($Value -is [datetime]) { $Value.ToString('yyyy-MM-ddTHH:mm:ss.fff') } else { $Value } }

function Set-PilotBolCursor([string]$Folder, $Since) {
  $Since = Format-TmwTime $Since
  if (-not $Since) { return }
  $old = Get-PilotBolCursor $Folder
  if ($old -and [datetime]$old -ge [datetime]$Since) { return }
  $null = New-Item -ItemType Directory -Force $Folder
  [pscustomobject]@{ since = $Since; updated_at = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Folder 'cursor.json')
}

function Write-PilotBolCache([string]$Folder, $Entry) {
  $null = New-Item -ItemType Directory -Force $Folder
  $Entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Folder "$($Entry.dispatchOrderId).json")
}

# one order's completion. done means Pilot answered with the order Kiosked (status 4; its status text can
# be stale) and a BOL on every item. Pilot turning the post down is an answer; not reaching Pilot (auth,
# throttling, a server error, a timeout) throws. either way the order stays pending and goes again next run.
function Send-PilotBol {
  param([Parameter(Mandatory)]$Batch, [Parameter(Mandatory)]$Session)
  try {
    $response = Set-PilotBol -Session $Session -Payload $Batch.payload
  } catch {
    $code = [int]$_.Exception.Response.StatusCode
    if ($code -lt 400 -or $code -ge 500 -or $code -in 401, 403, 429) { throw }
    return [pscustomobject]@{ done = $false; note = "turned down, HTTP $code $($_.ErrorDetails.Message)".Trim() }
  }
  $returned = $response.data.payload
  if ($response.status -ne 'success') { return [pscustomobject]@{ done = $false; note = "turned down: $($response.status)" } }
  $state = "status $($returned.dispatchOrderStatusTypeId), allItemsHasBols $($returned.allItemsHasBols)"
  $done = [long]$returned.dispatchOrderId -eq [long]$Batch.dispatchOrderId -and
    [int]$returned.dispatchOrderStatusTypeId -eq 4 -and $returned.allItemsHasBols -eq $true
  [pscustomobject]@{ done = $done; note = if ($done) { $state } else { "posted, Pilot shows order $($returned.dispatchOrderId) $state" } }
}

# DataAgent formatter: TMW rows in, plan file out
function Save-PilotBolPlan {
  param($Data, [hashtable]$Options)
  # an order file is kept keep_days (2 by default, like gravitate's finished orders): a done order from its send, a pending one
  # from when it was first staged, after which it stops going and says so
  if ($Options.KeepDays -gt 0) {
    $cutoff = [datetime]::UtcNow.AddDays(-$Options.KeepDays)
    foreach ($file in @(Get-PilotBolCacheFiles $Options.Cache)) {
      $cached = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      $at = if (Test-PilotBolPending $cached) { $cached.staged_at } else { $cached.sent_at }
      if ($at -and ([datetime]$at).ToUniversalTime() -ge $cutoff) { continue }
      if (Test-PilotBolPending $cached) { Write-Log "Dropped: TMW $($cached.tmwOrderId), Pilot $($cached.dispatchOrderId), pending since $($cached.staged_at), last: $($cached.pilot)" }
      Remove-Item -LiteralPath $file.FullName
    }
  }
  $rows = @($Data)
  $plan = New-PilotBolPlan -TmwRows $rows
  $ready = [Collections.Generic.List[object]]::new()
  $sent = [Collections.Generic.List[object]]::new()
  $touched = @{}
  foreach ($group in @($rows | Group-Object tmwOrderId)) { $touched[$group.Name] = Format-TmwTime @($group.Group.sourceUpdatedAt | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1] }
  foreach ($item in @($plan.ready)) {
    $item | Add-Member -NotePropertyName hash -NotePropertyValue (Get-PilotBolHash $item.payload) -Force
    $item | Add-Member -NotePropertyName sourceUpdatedAt -NotePropertyValue $touched["$($item.tmwOrderId)"] -Force
    $cached = Get-PilotBolCache $Options.Cache $item.dispatchOrderId
    if ($cached -and $cached.hash -eq $item.hash -and -not (Test-PilotBolPending $cached)) { $sent.Add([pscustomobject]@{ item = $item; at = $cached.sent_at }) } else { $ready.Add($item) }
  }
  Write-Log "Orders : $(@($rows | Group-Object tmwOrderId).Count) completed in TMW, $($ready.Count) ready, $(@($plan.deferred).Count) waiting, $($sent.Count) already done"
  foreach ($item in @($plan.deferred)) { Write-Log "Waiting: TMW $($item.tmwOrderId): $($item.reason)" }
  foreach ($s in $sent) { Write-Log "Already: TMW $($s.item.tmwOrderId), Pilot $($s.item.dispatchOrderId), done $($s.at)" }
  $latest = @($rows.sourceUpdatedAt | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
  $null = New-Item -ItemType Directory -Force (Split-Path $Options.Path)
  [pscustomobject]@{
    ready = @($ready); deferred = @($plan.deferred)
    cursor = Format-TmwTime $latest
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Options.Path
}

# DataAgent destination: stage every ready order as pending, post them in parallel, then move the cursor. an order Pilot does not
# finish, or that could not reach Pilot, stays pending and goes again next run; the run stays green, like gravitate
function Send-PilotBolPlan {
  param([string]$Path, [hashtable]$Options)
  $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $ready = @($plan.ready)
  $staged = @{}
  foreach ($batch in $ready) {
    $cached = Get-PilotBolCache $Options.Cache $batch.dispatchOrderId
    $entry = [ordered]@{
      state = 'pending'; tmwOrderId = $batch.tmwOrderId; dispatchOrderId = $batch.dispatchOrderId; hash = $batch.hash
      staged_at = if ((Test-PilotBolPending $cached) -and $cached.hash -eq $batch.hash) { $cached.staged_at } else { [datetime]::UtcNow.ToString('o') }
      sent_at = $null; pilot = if (Test-PilotBolPending $cached) { $cached.pilot }; sourceUpdatedAt = $batch.sourceUpdatedAt; payload = @($batch.payload)
    }
    Write-PilotBolCache $Options.Cache ([pscustomobject]$entry)
    $staged["$($batch.dispatchOrderId)"] = $entry
  }

  if ($ready.Count) {
    $session = New-PilotCarrierSession $Options.Pilot
    $module = Join-Path $PSScriptRoot 'PilotCarrierIntegration.psd1'
    $throttle = if ($Options.ThrottleLimit) { [int]$Options.ThrottleLimit } else { 8 }
    # one token for every post; without one, nothing reaches Pilot this run
    $tokenError = try { $null = Get-PilotToken $session } catch { $_.Exception.Message }
    $results = if ($tokenError) {
      @($ready | ForEach-Object { [pscustomobject]@{ batch = $_; outcome = $null; error = "no token: $tokenError" } })
    } else { @($ready | ForEach-Object -Parallel {
      $batch = $_
      try {
        $outcome = & (Import-Module $using:module -PassThru) { param($b, $s) Send-PilotBol -Batch $b -Session $s } $batch $using:session
        [pscustomobject]@{ batch = $batch; outcome = $outcome; error = $null }
      } catch {
        [pscustomobject]@{ batch = $batch; outcome = $null; error = $_.Exception.Message }
      }
    } -ThrottleLimit $throttle) }
    foreach ($result in $results) {
      $label = "TMW $($result.batch.tmwOrderId), Pilot $($result.batch.dispatchOrderId), BOL $(@($result.batch.payload.billOfLadingNumber) -join ',')"
      $entry = $staged["$($result.batch.dispatchOrderId)"]
      if ($result.error) {
        $entry.pilot = "not reached: $($result.error)"
        Write-Log "Failed : $label`: $($result.error)"
      } elseif (-not $result.outcome.done) {
        $entry.pilot = $result.outcome.note
        Write-Log "Not done: $label`: $($result.outcome.note)"
      } else {
        $entry.state = 'done'; $entry.sent_at = [datetime]::UtcNow.ToString('o'); $entry.pilot = $result.outcome.note
        Write-Log "Sent   : $label, $($result.outcome.note)"
      }
      Write-PilotBolCache $Options.Cache ([pscustomobject]$entry)
    }
  } else {
    Write-Log 'Nothing ready to send'
  }

  $pending = @(Get-PilotBolCacheFiles $Options.Cache | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { Test-PilotBolPending $_ })
  $oldest = @($pending.staged_at | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[0]
  $held = @($pending.sourceUpdatedAt | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[0]
  Set-PilotBolCursor $Options.Cache $(if ($held) { $held } else { $plan.cursor })
  Write-Log "Summary: $(@($staged.Values | Where-Object { $_.state -eq 'done' }).Count) sent, $($pending.Count) pending$(if ($oldest) { " (oldest staged $($oldest.ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))Z)" }), cursor $(Get-PilotBolCursor $Options.Cache)"
}
