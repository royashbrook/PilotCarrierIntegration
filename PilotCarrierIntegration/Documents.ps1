# Documents: scanned BOLs from an imaging database -> the Pilot order item they belong to -> Pilot PUT /document.
# DocumentAgent does the run (receipts, fetch, one delivery per upload); this file correlates and uploads.

function Test-PilotValue($Value) {
  $null -ne $Value -and $Value -ne [DBNull]::Value -and ([string]$Value).Trim()
}

function Get-PilotKey($Value) {
  if (-not (Test-PilotValue $Value)) { return $null }
  $text = ([string]$Value).Trim()
  $number = 0L
  if ([long]::TryParse($text, [ref]$number)) { return [string]$number }
  $text.ToUpperInvariant()
}

# query rows (one per document and order reference) -> one object per document
function ConvertFrom-PilotDocumentRows {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows)
  foreach ($group in @($Rows | Group-Object EbeDocumentId)) {
    $first = $group.Group | Select-Object -First 1
    [pscustomobject]@{
      ebeDocumentId = [long]$first.EbeDocumentId
      documentType = ([string]$first.DocumentType).Trim().ToUpperInvariant()
      orderNumber = ([string]$first.OrderNumber).Trim()
      bolNumber = ([string]$first.BolNumber).Trim()
      pilotOrderRefs = @($group.Group.PilotOrderRef | Where-Object { Test-PilotValue $_ } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
      indexedAt = [datetime]$first.IndexedAt
      dispatchOrderId = if (Test-PilotValue $first.DispatchOrderId) { [long]$first.DispatchOrderId } else { $null }
      dispatchOrderItemId = if (Test-PilotValue $first.DispatchOrderItemId) { [long]$first.DispatchOrderItemId } else { $null }
      attachmentName = if (Test-PilotValue $first.AttachmentName) { [string]$first.AttachmentName } else { "BOL-$($first.BolNumber)-$($first.EbeDocumentId).pdf" }
    }
  }
}

function Get-PilotItemBolKeys {
  param([Parameter(Mandatory)]$Item)
  @(
    @($Item.billOfLadings).billOfLadingNumber
    @($Item.dropDetails).billOfLadingNumber
    @($Item.pullDetails).billOfLadingNumber
    @($Item.dispatchOrderItemAttachments).bol
  ) | ForEach-Object { Get-PilotKey $_ } | Where-Object { $_ } | Sort-Object -Unique
}

# each document -> the one Pilot order item it belongs to. ready, deferred (no single match yet) or skipped (already on the item)
function New-PilotDocumentPlan {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$Documents,
    [Parameter(Mandatory)][AllowEmptyCollection()]$PilotBols,
    [Parameter(Mandatory)][AllowEmptyCollection()]$PilotOrders
  )
  $ready = [Collections.Generic.List[object]]::new()
  $deferred = [Collections.Generic.List[object]]::new()
  $skipped = [Collections.Generic.List[object]]::new()

  foreach ($document in @($Documents)) {
    $bolKey = Get-PilotKey $document.bolNumber
    $orderKeys = @(@($document.pilotOrderRefs) + @($document.dispatchOrderId) | ForEach-Object { Get-PilotKey $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $bolMatches = @($PilotBols | Where-Object { (Get-PilotKey $_.bolNumber) -eq $bolKey -and $orderKeys -contains (Get-PilotKey $_.orderNumber) })
    $orderMatches = @($bolMatches.orderNumber | ForEach-Object { Get-PilotKey $_ } | Sort-Object -Unique)

    if ($orderMatches.Count -ne 1) {
      $deferred.Add([pscustomobject]@{ ebeDocumentId = $document.ebeDocumentId; reason = if ($orderMatches.Count) { 'multiple Pilot order/BOL matches' } else { 'no Pilot order/BOL match' } })
      continue
    }

    $dispatchOrderId = [long]$orderMatches[0]
    $orders = @($PilotOrders | Where-Object { (Get-PilotKey $_.dispatchOrderId) -eq (Get-PilotKey $dispatchOrderId) })
    if ($orders.Count -ne 1) {
      $deferred.Add([pscustomobject]@{ ebeDocumentId = $document.ebeDocumentId; dispatchOrderId = $dispatchOrderId; reason = if ($orders.Count) { 'multiple Pilot order reads' } else { 'Pilot order not in read window' } })
      continue
    }

    $order = $orders[0]
    $items = @($order.dispatchOrderItems | Where-Object { -not $_.isDeleted -and $_.dispatchOrderItemId })
    $itemMatches = @($items | Where-Object { @(Get-PilotItemBolKeys $_) -contains $bolKey })
    if (-not $itemMatches.Count -and $items.Count -eq 1) {
      $orderBolKeys = @(@(@($order.billOfLadings).billOfLadingNumber) + @($order.bolNumber) | ForEach-Object { Get-PilotKey $_ } | Where-Object { $_ } | Sort-Object -Unique)
      if ($orderBolKeys -contains $bolKey) { $itemMatches = @($items[0]) }
    }
    if (-not $itemMatches.Count) {
      $deferred.Add([pscustomobject]@{ ebeDocumentId = $document.ebeDocumentId; dispatchOrderId = $dispatchOrderId; reason = 'no Pilot item/BOL match' })
      continue
    }

    foreach ($item in $itemMatches) {
      $itemId = [long]$item.dispatchOrderItemId
      $existing = @(@($item.dispatchOrderItemAttachments).attachmentName | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
      if ($existing -contains [string]$document.attachmentName) {
        $skipped.Add([pscustomobject]@{ ebeDocumentId = $document.ebeDocumentId; dispatchOrderId = $dispatchOrderId; dispatchOrderItemId = $itemId; reason = 'attachment already present' })
        continue
      }
      $ready.Add([pscustomobject]@{
          ebeDocumentId = [long]$document.ebeDocumentId
          bolNumber = [string]$document.bolNumber
          indexedAt = [datetime]$document.indexedAt
          dispatchOrderId = $dispatchOrderId
          dispatchOrderItemId = $itemId
          attachmentName = [string]$document.attachmentName
        })
    }
  }
  [pscustomobject]@{ ready = @($ready); deferred = @($deferred); skipped = @($skipped) }
}

# the Pilot upload body for one document
function New-PilotDocumentPayload {
  param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][byte[]]$Content)
  if (-not $Document.dispatchOrderId -or -not $Document.dispatchOrderItemId -or -not $Document.attachment_name) {
    throw "Document $($Document.document_id) has no Pilot order item or attachment name."
  }
  if ($Content.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($Content, 0, 5) -ne '%PDF-') {
    throw "Document $($Document.document_id) is not a PDF."
  }
  # the row came back through JSON, which turns the ISO string into a DateTime
  $bolDatetime = $Document.bol_datetime
  if ($bolDatetime -is [datetime]) { $bolDatetime = $bolDatetime.ToString('yyyy-MM-ddTHH:mm:ss') }
  [pscustomobject][ordered]@{
    attachmentName = [string]$Document.attachment_name
    dispatchOrderId = [long]$Document.dispatchOrderId
    dispatchOrderItemId = [long]$Document.dispatchOrderItemId
    bolDatetime = [string]$bolDatetime
    file = "data:application/pdf;base64,$([Convert]::ToBase64String($Content))"
    isBase64Encoded = $true
  }
}

# DocumentAgent items: every scanned BOL in the window, correlated to its Pilot order item, one row per upload
function Read-PilotCarrierDocuments {
  param([hashtable]$Options)
  $script:PilotDocumentSession = New-PilotCarrierSession $Options.Pilot
  $days = [int]$Options.LookbackDays
  $query = @{} + $Options.Query
  # Invoke-Sqlcmd takes -Variable untyped and rejects pipeline-wrapped strings, so plain strings only
  $query.Variable = [string[]]@(@($query.Variable) + "LookbackDays=$days" | Where-Object { $_ })
  Import-Module SqlServer -RequiredVersion 22.4.5.1 -Cmdlet Invoke-Sqlcmd
  $rows = @(Invoke-Sqlcmd -OutputAs DataRows @query)
  $documents = @(ConvertFrom-PilotDocumentRows -Rows $rows)
  $bols = @(Get-PilotBol -Session $script:PilotDocumentSession)
  $orders = @(Get-PilotOrder -Session $script:PilotDocumentSession -StartDate ([datetime]::Today.AddDays(-$days)) -EndDate ([datetime]::Today.AddDays(1)))
  $plan = New-PilotDocumentPlan -Documents $documents -PilotBols $bols -PilotOrders $orders
  Write-Log "Pilot  : $($documents.Count) documents, $($bols.Count) Pilot BOLs, $($orders.Count) Pilot orders, $($plan.ready.Count) ready, $($plan.skipped.Count) already on Pilot, $($plan.deferred.Count) waiting"
  foreach ($d in $plan.deferred) { Write-Log "Waiting: document $($d.ebeDocumentId): $($d.reason)" }
  foreach ($d in $plan.ready) {
    [pscustomobject]@{
      key = '{0}-{1}-{2}' -f $d.dispatchOrderId, $d.dispatchOrderItemId, $d.ebeDocumentId
      document_id = $d.ebeDocumentId
      file_name = $d.attachmentName
      attachment_name = $d.attachmentName
      bol_number = $d.bolNumber
      dispatchOrderId = $d.dispatchOrderId
      dispatchOrderItemId = $d.dispatchOrderItemId
      # the scan's index time read as the runner's local time, sent to Pilot in UTC
      bol_datetime = $d.indexedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
    }
  }
}

# DocumentAgent delivery: one PDF to the Pilot order item it belongs to
function Send-PilotCarrierDocument {
  param([string]$Key, [string[]]$Files, [hashtable]$Options, [object[]]$Documents)
  if ($Files.Count -ne 1 -or $Documents.Count -ne 1) { throw "Upload $Key needs exactly one file." }
  if (-not $script:PilotDocumentSession) { $script:PilotDocumentSession = New-PilotCarrierSession $Options.Pilot }
  $document = $Documents[0]
  $payload = New-PilotDocumentPayload -Document $document -Content ([IO.File]::ReadAllBytes($Files[0]))
  $response = Set-PilotDocument -Session $script:PilotDocumentSession -Payload $payload
  if ($response.status -and $response.status -ne 'success') { throw "Pilot said $($response.status)" }
  [ordered]@{
    status = if ($response.status) { [string]$response.status } else { 'accepted' }
    dispatchOrderId = [long]$document.dispatchOrderId
    dispatchOrderItemId = [long]$document.dispatchOrderItemId
  }
}
