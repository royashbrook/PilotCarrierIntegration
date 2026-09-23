BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  function InModule([scriptblock]$Block, [object[]]$Arguments) { & (Get-Module PilotCarrierIntegration) $Block @Arguments }
  function New-TestItem([long]$Id, [string]$Bol, $Attachments = @()) {
    [pscustomobject]@{
      dispatchOrderItemId = $Id; isDeleted = $false
      billOfLadings = @([pscustomobject]@{ billOfLadingNumber = $Bol })
      dropDetails = @(); pullDetails = @(); dispatchOrderItemAttachments = @($Attachments)
    }
  }
  function New-TestRow([long]$DocumentId, [string]$Bol, [string]$OrderRef) {
    [pscustomobject]@{
      EbeDocumentId = $DocumentId; DocumentType = 'bol'; OrderNumber = ' 70001 '; BolNumber = $Bol; PilotOrderRef = $OrderRef
      IndexedAt = [datetime]'2026-01-02T08:30:00'; DispatchOrderId = [DBNull]::Value; DispatchOrderItemId = [DBNull]::Value
      AttachmentName = "BOL-$Bol-$DocumentId.pdf"
    }
  }
}

Describe 'Pilot document plan' {
  BeforeEach {
    $documents = @(InModule { param($r) ConvertFrom-PilotDocumentRows -Rows $r } @(, @(New-TestRow 9001 '4242' '5001')))
    $bols = @([pscustomobject]@{ bolNumber = 4242; orderNumber = 5001 })
    $orders = @([pscustomobject]@{ dispatchOrderId = 5001; billOfLadings = @(); dispatchOrderItems = @(New-TestItem 6001 '4242') })
    function Plan { InModule { param($d, $b, $o) New-PilotDocumentPlan -Documents $d -PilotBols $b -PilotOrders $o } @($documents, $bols, $orders) }
  }

  It 'groups query rows into one document per scan' {
    $rows = @((New-TestRow 9001 '4242' '5001'), (New-TestRow 9001 '4242' '5001'), (New-TestRow 9002 '4243' $null))
    $docs = @(InModule { param($r) ConvertFrom-PilotDocumentRows -Rows $r } @(, $rows))
    $docs.Count | Should -Be 2
    $docs[0].pilotOrderRefs | Should -Be @('5001')
    $docs[0].documentType | Should -Be 'BOL'
    $docs[0].orderNumber | Should -Be '70001'
    $docs[0].dispatchOrderId | Should -BeNullOrEmpty
    $docs[1].pilotOrderRefs | Should -BeNullOrEmpty
  }

  It 'is ready only when the Pilot order and the BOL both match' {
    $plan = Plan
    @($plan.ready).Count | Should -Be 1
    $plan.ready[0].dispatchOrderId | Should -Be 5001
    $plan.ready[0].dispatchOrderItemId | Should -Be 6001
    $plan.ready[0].attachmentName | Should -Be 'BOL-4242-9001.pdf'
  }

  It 'waits when Pilot has no such BOL on the order' {
    $bols = @([pscustomobject]@{ bolNumber = 4242; orderNumber = 5999 })
    $plan = Plan
    @($plan.ready).Count | Should -Be 0
    $plan.deferred[0].reason | Should -Be 'no Pilot order/BOL match'
  }

  It 'waits when the Pilot order is outside the read window' {
    $orders = @()
    (Plan).deferred[0].reason | Should -Be 'Pilot order not in read window'
  }

  It 'waits when no Pilot item carries the BOL' {
    $orders[0].dispatchOrderItems = @(New-TestItem 6001 'OTHER'), @(New-TestItem 6002 'OTHER2')
    (Plan).deferred[0].reason | Should -Be 'no Pilot item/BOL match'
  }

  It 'uses the order BOL when the order has a single item' {
    $orders[0].dispatchOrderItems = @(New-TestItem 6001 'OTHER')
    $orders[0].billOfLadings = @([pscustomobject]@{ billOfLadingNumber = 4242 })
    (Plan).ready[0].dispatchOrderItemId | Should -Be 6001
  }

  It 'targets only the matching item, and every item that carries the BOL' {
    $orders[0].dispatchOrderItems = @((New-TestItem 6001 '4242'), (New-TestItem 6002 'OTHER'))
    @((Plan).ready.dispatchOrderItemId) | Should -Be @(6001)
    $orders[0].dispatchOrderItems = @((New-TestItem 6001 '4242'), (New-TestItem 6002 '4242'))
    @((Plan).ready.dispatchOrderItemId) | Should -Be @(6001, 6002)
  }

  It 'skips a document already attached to the Pilot item' {
    $orders[0].dispatchOrderItems = @(New-TestItem 6001 '4242' @([pscustomobject]@{ attachmentName = 'BOL-4242-9001.pdf' }))
    $plan = Plan
    @($plan.ready).Count | Should -Be 0
    $plan.skipped[0].reason | Should -Be 'attachment already present'
  }
}

Describe 'Pilot document payload' {
  BeforeEach {
    $document = [pscustomobject]@{ document_id = 9001; attachment_name = 'BOL-4242-9001.pdf'; dispatchOrderId = 5001; dispatchOrderItemId = 6001; bol_datetime = '2026-01-02T13:30:00' }
    [byte[]]$pdf = [Text.Encoding]::ASCII.GetBytes('%PDF-1.4 test')
    function Payload($d, $c) { InModule { param($x, $y) New-PilotDocumentPayload -Document $x -Content $y } @($d, $c) }
  }

  It 'targets the Pilot order item with the PDF inline' {
    $payload = Payload $document $pdf
    $payload.dispatchOrderId | Should -Be 5001
    $payload.dispatchOrderItemId | Should -Be 6001
    $payload.attachmentName | Should -Be 'BOL-4242-9001.pdf'
    $payload.bolDatetime | Should -Be '2026-01-02T13:30:00'
    $payload.file | Should -Be "data:application/pdf;base64,$([Convert]::ToBase64String($pdf))"
    $payload.isBase64Encoded | Should -BeTrue
  }

  It 'keeps the Pilot date format when the row came back from JSON as a date' {
    $round = $document | ConvertTo-Json | ConvertFrom-Json
    $round.bol_datetime | Should -BeOfType [datetime]
    (Payload $round $pdf).bolDatetime | Should -Be '2026-01-02T13:30:00'
  }

  It 'refuses anything that is not a PDF, or has no Pilot item' {
    { Payload $document ([Text.Encoding]::ASCII.GetBytes('<html>')) } | Should -Throw '*not a PDF*'
    $document.dispatchOrderItemId = $null
    { Payload $document $pdf } | Should -Throw '*no Pilot order item*'
  }
}

Describe 'a Pilot document run' {
  BeforeAll {
    $job = Join-Path $TestDrive 'job'
    New-Item -ItemType Directory $job | Out-Null
    $env:PCI_TEST_SECRET = 'from-env-secret'
    function Set-Settings([hashtable]$Extra = @{}) {
      $settings = @{
        keepdays = 10; purgefiles = '*.log'; lookback_days = 7
        pilot = @{ base_url = 'https://pilot.example'; token_url = 'https://login.example'; scope = 's'; client_id = 'id'; client_secret = 'env:PCI_TEST_SECRET'; carrier_id = 123 }
        query = @{ InputFile = 'get-data.sql'; ConnectionString = 'x'; Variable = @('BillTo=ACMEWHL') }
        documents = @{ adapter = 'ships'; args = @{ BaseUrl = 'https://portal.example/'; Username = 'reader'; Password = 'p' } }
      }
      foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
      $settings | ConvertTo-Json -Depth 8 | Set-Content "$job/settings.json"
    }
    function Get-Log { Get-Content (Join-Path $job ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
  }
  BeforeEach {
    Remove-Item "$job/sent", "$job/out", "$job/*.log" -Recurse -Force -ErrorAction Ignore
    $global:PciRows = @((New-TestRow 9001 '4242' '5001'), (New-TestRow 9002 '4343' '5002'))
    Mock New-PilotSession -ModuleName PilotCarrierIntegration { [pscustomobject]@{ CarrierId = $CarrierId; Secret = $Credential.GetNetworkCredential().Password } }
    Mock Invoke-Sqlcmd -ModuleName PilotCarrierIntegration { $global:PciRows }
    Mock Get-PilotBol -ModuleName PilotCarrierIntegration { [pscustomobject]@{ bolNumber = 4242; orderNumber = 5001 } }
    Mock Get-PilotOrder -ModuleName PilotCarrierIntegration {
      [pscustomobject]@{ dispatchOrderId = 5001; billOfLadings = @(); dispatchOrderItems = @((New-TestItem 6001 '4242'), (New-TestItem 6002 '4242')) }
    }
    Mock Set-PilotDocument -ModuleName PilotCarrierIntegration { [pscustomobject]@{ status = 'success' } }
    Mock New-ShipsSession -ModuleName DocumentAgent { [pscustomobject]@{ BaseUrl = $BaseUrl } }
    Mock Get-ShipsDocument -ModuleName DocumentAgent { , ([Text.Encoding]::ASCII.GetBytes("%PDF-$DocumentId")) }
    Set-Location $TestDrive
  }

  It 'uploads each ready document to each Pilot item once, and logs what waits' {
    Set-Settings
    Invoke-PilotCarrierDocuments "$job/settings.json"
    Should -Invoke Set-PilotDocument -ModuleName PilotCarrierIntegration -Times 2 -Exactly
    Should -Invoke Set-PilotDocument -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter {
      $Payload.dispatchOrderItemId -eq 6002 -and $Payload.bolDatetime -eq ([datetime]'2026-01-02T08:30:00').ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') -and
      $Payload.file -eq "data:application/pdf;base64,$([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('%PDF-9001')))"
    }
    # one scan, two items: fetched once, uploaded twice
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 1 -Exactly
    Should -Invoke Invoke-Sqlcmd -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter {
      $InputFile -eq 'get-data.sql' -and $Variable -is [string[]] -and ($Variable -join ',') -eq 'BillTo=ACMEWHL,LookbackDays=7'
    }
    Should -Invoke New-PilotSession -ModuleName PilotCarrierIntegration -ParameterFilter { $Credential.GetNetworkCredential().Password -eq 'from-env-secret' -and $CarrierId -eq 123 }
    (Get-Content "$job/sent/5001-6001-9001.json" -Raw | ConvertFrom-Json).delivery.status | Should -Be 'success'
    Test-Path "$job/sent/5001-6002-9001.json" | Should -BeTrue
    $log = Get-Log
    $log | Should -Contain 'Pilot  : 2 documents, 1 Pilot BOLs, 1 Pilot orders, 2 ready, 0 already on Pilot, 1 waiting'
    $log | Should -Contain 'Waiting: document 9002: no Pilot order/BOL match'
    $log | Should -Contain 'Sent   : 5001-6002-9001 (BOL-4242-9001.pdf)'
  }

  It 'never uploads the same document to the same item twice' {
    Set-Settings
    Invoke-PilotCarrierDocuments "$job/settings.json"
    Invoke-PilotCarrierDocuments "$job/settings.json"
    Should -Invoke Set-PilotDocument -ModuleName PilotCarrierIntegration -Times 2 -Exactly
    Get-Log | Should -Contain 'No data available'
  }

  It 'keeps no receipt when Pilot refuses, and fails the run naming it' {
    Set-Settings
    Mock Set-PilotDocument -ModuleName PilotCarrierIntegration { if ($Payload.dispatchOrderItemId -eq 6001) { [pscustomobject]@{ status = 'error' } } else { [pscustomobject]@{ status = 'success' } } }
    { Invoke-PilotCarrierDocuments "$job/settings.json" } | Should -Throw '*5001-6001-9001*'
    Test-Path "$job/sent/5001-6001-9001.json" | Should -BeFalse
    Test-Path "$job/sent/5001-6002-9001.json" | Should -BeTrue
    Get-Log | Should -Contain 'Failed : 5001-6001-9001: Pilot said error'
  }

  It 'dry_run reads and plans, and fetches and uploads nothing' {
    Set-Settings @{ dry_run = $true }
    Invoke-PilotCarrierDocuments "$job/settings.json"
    Get-Log | Should -Contain 'Dry run, not sending: 5001-6001-9001, 5001-6002-9001'
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 0
    Should -Invoke Set-PilotDocument -ModuleName PilotCarrierIntegration -Times 0
  }
}
