Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force

InModuleScope PilotCarrierIntegration {
BeforeAll {
  $fixtures = Join-Path $PSScriptRoot 'fixtures'
  $script:cfg = Get-Content (Join-Path $fixtures 'order-settings.json') -Raw | ConvertFrom-Json
  $script:rawOrder = (Get-Content (Join-Path $fixtures 'pilot-order.json') -Raw | ConvertFrom-Json)[0]
  $script:references = [pscustomobject]@{
    locations = @{ '55979' = (Get-Content (Join-Path $fixtures 'pilot-location.json') -Raw | ConvertFrom-Json)[0] }
    terminals = @{ '14673' = (Get-Content (Join-Path $fixtures 'pilot-terminal.json') -Raw | ConvertFrom-Json)[0] }
    contracts = @{ '10180' = (Get-Content (Join-Path $fixtures 'pilot-contract.json') -Raw | ConvertFrom-Json)[0] }
  }
  $script:canonical = ConvertFrom-PilotOrder $rawOrder $cfg $references
  $script:session = New-PilotSession -BaseUrl https://pilot.example -TokenUrl https://login.example -Scope s -CarrierId 123 `
    -Credential ([pscredential]::new('id', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force)))
}

Describe 'Pilot order translation' {
  It 'preserves Pilot order, source, item, terminal, location, contract, and product keys' {
    $canonical.pilotOrderId | Should -Be '10877997'
    $canonical.pilotSourceOrderId | Should -Be 'pilot-source-10877997'
    @($canonical.pilotOrderItemIds) | Should -Be @('11888001')
    $canonical.stops[0].locationCode | Should -Be '14673'
    $canonical.stops[1].locationCode | Should -Be '55979'
    @($canonical.contractSystemIds) | Should -Be @('10180')
    $canonical.stops[0].freight[0].supplierContractId | Should -Be '10180'
    $canonical.stops[0].freight[0].supplierName | Should -Be 'CARGILL'
    $canonical.stops[0].freight[0].supplierDescription | Should -Be 'CARGILL INCORPORATED'
    $canonical.stops[0].freight[0].commodityCode | Should -Be 'B99-UL'
  }
  It 'builds a pickup and delivery with freight on both stops' {
    @($canonical.stops).Count | Should -Be 2
    @($canonical.stops.type) | Should -Be @('PU', 'DR')
    $canonical.stops[0].freight[0].quantity | Should -Be 4700
    $canonical.stops[1].freight[0].quantity | Should -Be 4700
  }
  It 'hydrates complete addresses while leaving company IDs unresolved for TMW mapping' {
    $canonical.stops[0].name | Should -Be 'EXAMPLE TERMINAL'
    $canonical.stops[0].address1 | Should -Be '100 TERMINAL WAY'
    $canonical.stops[0].address2 | Should -Be 'GATE 2'
    $canonical.stops[1].name | Should -Be 'EXAMPLE STORE 100'
    $canonical.stops[1].address1 | Should -Be '200 STORE ROAD'
    $canonical.stops[1].city | Should -Be 'KNOXVILLE'
  }
  It 'uses the Pilot wholesale bill-to' {
    $canonical.billto | Should -Be 'ACMEWHL'
    $cfg.create.division | Should -Be 'DIV'
    $cfg.create.scac | Should -Be 'SCAC'
  }
  It 'groups two products on the same route into two multi-freight stops' {
    $multi = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second = $multi.dispatchOrderItems[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second.dispatchOrderItemId = 11888002
    $second.gallons = 3000
    $second.productName = 'REGULAR UNLEADED'
    $multi.dispatchOrderItems = @($multi.dispatchOrderItems[0], $second)
    $converted = ConvertFrom-PilotOrder $multi $cfg $references
    @($converted.stops).Count | Should -Be 2
    @($converted.stops[0].freight).Count | Should -Be 2
  }
  It 'keeps suppliers on their items across multiple pickup and delivery stops' {
    $multi = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second = $multi.dispatchOrderItems[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second.dispatchOrderItemId = 11888002
    $second.lineOfOperationsSystemId = 14674
    $second.locationSystemId = 55980
    $second.looSystemId = 10181
    $multi.dispatchOrderItems = @($multi.dispatchOrderItems[0], $second)

    $terminal = $references.terminals['14673'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $terminal.terminalId = 14674
    $terminal.name = 'SECOND TERMINAL'
    $location = $references.locations['55979'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $location.locationSystemId = 55980
    $location.description = 'SECOND LOCATION'
    $contract = $references.contracts['10180'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $contract.contractSystemId = 10181
    $contract.contractName = 'SECOND SUPPLIER'
    $multiReferences = [pscustomobject]@{
      locations = @{ '55979' = $references.locations['55979']; '55980' = $location }
      terminals = @{ '14673' = $references.terminals['14673']; '14674' = $terminal }
      contracts = @{ '10180' = $references.contracts['10180']; '10181' = $contract }
    }

    $converted = ConvertFrom-PilotOrder $multi $cfg $multiReferences
    @($converted.stops.type) | Should -Be @('PU', 'PU', 'DR', 'DR')
    @($converted.contractSystemIds) | Should -Be @('10180', '10181')
    $converted.stops[1].freight[0].supplierContractId | Should -Be '10181'
    $converted.stops[1].freight[0].supplierName | Should -Be 'SECOND SUPPLIER'
  }
  It 'stages an item with no pickup terminal as an UNKNOWN pickup with no address' {
    $raw = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $raw.dispatchOrderItems[0].lineOfOperationsSystemId = $null
    $converted = ConvertFrom-PilotOrder $raw $cfg $references
    $pickup = @($converted.stops | Where-Object type -eq 'PU')[0]
    $pickup.locationCode | Should -Be 'UNKNOWN'
    $pickup.name | Should -Be 'NO TERMINAL'
    $pickup.address1 | Should -BeNullOrEmpty
    $pickup.city | Should -BeNullOrEmpty
    @($converted.stops | Where-Object type -eq 'DR')[0].city | Should -Not -BeNullOrEmpty
    $pickupIndex = [array]::IndexOf(@($converted.stops), $pickup) + 1
    $command = New-TmwOrderCommand $converted $cfg
    $command.sql | Should -Not -Match "declare @city_code$pickupIndex int"
    $command.sql | Should -Match "rtrim\(s\.cmp_name\) in \('NO TERMINAL', 'NO LOCATION'\)"
    { New-DxArchivePlan $converted $cfg (Get-Date) } | Should -Not -Throw
  }
  It 'stages an item with no contract as an UNKNOWN supplier' {
    $raw = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $raw.dispatchOrderItems[0].looSystemId = $null
    $converted = ConvertFrom-PilotOrder $raw $cfg $references
    $freight = @($converted.stops)[0].freight[0]
    $freight.supplierContractId | Should -Be 'UNKNOWN'
    $freight.supplierName | Should -Be 'NO SUPPLIER'
    { New-TmwOrderCommand $converted $cfg } | Should -Not -Throw
  }
  It 'fails closed on data required to stage an order' {
    $bad = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $bad.dispatchOrderItems[0].gallons = 0
    { ConvertFrom-PilotOrder $bad $cfg $references } | Should -Throw '*positive gallon quantity*'
  }
  It 'stages ids missing from Pilot reference data with the id and no address' {
    $raw = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $raw.dispatchOrderItems[0].lineOfOperationsSystemId = 99999999
    $empty = [pscustomobject]@{ locations = @{}; terminals = @{}; contracts = @{} }
    $converted = ConvertFrom-PilotOrder $raw $cfg $empty
    $pickup = @($converted.stops | Where-Object type -eq 'PU')[0]
    $pickup.locationCode | Should -Be '99999999'
    $pickup.name | Should -Be 'NO TERMINAL'
    $pickup.address1 | Should -BeNullOrEmpty
    $drop = @($converted.stops | Where-Object type -eq 'DR')[0]
    $drop.locationCode | Should -Be '55979'
    $drop.name | Should -Be 'NO LOCATION'
    $drop.city | Should -BeNullOrEmpty
    $pickup.freight[0].supplierContractId | Should -Be '10180'
    $pickup.freight[0].supplierName | Should -Be 'NO SUPPLIER'
    $command = New-TmwOrderCommand $converted $cfg
    $command.sql | Should -Not -Match 'declare @city_code\d int'
    $command.sql | Should -Match "rtrim\(s\.cmp_name\) in \('NO TERMINAL', 'NO LOCATION'\)"
  }
  It 'stages a partial Pilot address with each missing part marked for dispatch' {
    $incomplete = $references | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $incomplete.locations['55979'].address1 = ''
    $incomplete.locations['55979'].stateCode = ''
    $drop = @(@(ConvertFrom-PilotOrder $rawOrder $cfg $incomplete).stops | Where-Object type -eq 'DR')[0]
    $drop.address1 | Should -Be 'MISSING'
    $drop.state | Should -Be '??'
    $drop.city | Should -Not -Be 'MISSING'
  }
  It 'does not second-guess Pilot on an inactive contract' {
    $inactiveContract = $references.contracts['10180'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $inactiveContract.isActive = $false
    $inactive = [pscustomobject]@{ locations = $references.locations; terminals = $references.terminals; contracts = @{ '10180' = $inactiveContract } }
    @(ConvertFrom-PilotOrder $rawOrder $cfg $inactive).Count | Should -Be 1
  }
  It 'uses explicit placeholders when Pilot omits display names' {
    $blankContract = $references.contracts['10180'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $blankContract.contractName = ''
    $blankContract.contractDescription = ''
    $blankTerminal = $references.terminals['14673'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $blankTerminal.name = ''
    $blankLocation = $references.locations['55979'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $blankLocation.description = ''
    $blankOrder = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $blankOrder.dispatchOrderItems[0].productName = ''
    $blankOrder.dispatchOrderItems[0] | Add-Member -NotePropertyName wraProductDescription -NotePropertyValue ''
    $blankOrder.dispatchOrderItems[0] | Add-Member -NotePropertyName wraProductLongName -NotePropertyValue ''
    $blank = [pscustomobject]@{
      locations = @{ '55979' = $blankLocation }
      terminals = @{ '14673' = $blankTerminal }
      contracts = @{ '10180' = $blankContract }
    }
    $converted = ConvertFrom-PilotOrder $blankOrder $cfg $blank
    $converted.stops[0].freight[0].supplierName | Should -Be 'NO SUPPLIER'
    $converted.stops[0].freight[0].supplierDescription | Should -Be 'NO SUPPLIER'
    @($converted.stops | Where-Object type -eq 'PU')[0].name | Should -Be 'NO TERMINAL'
    @($converted.stops | Where-Object type -eq 'DR')[0].name | Should -Be 'NO LOCATION'
    $converted.stops[0].freight[0].commodityName | Should -Be 'NO PRODUCT'
  }
  It 'uses the delivery window rather than Pilot planning timestamps' {
    $canonical.deliveryWindowStart | Should -Be ([datetime]'2026-07-27T23:00:00')
    $canonical.deliveryWindowEnd | Should -Be ([datetime]'2026-07-28T06:00:00')
    $canonical.stops[0].earliest | Should -Be ([datetime]'2026-07-27T23:00:00')
    $canonical.stops[0].latest | Should -Be ([datetime]'2026-07-28T06:00:00')
  }
  It 'fails closed on a missing or reversed delivery window' {
    $bad = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $bad.deliveryWindowStartDateTime = $null
    { ConvertFrom-PilotOrder $bad $cfg $references } | Should -Throw '*no complete delivery window*'

    $bad = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $bad.deliveryWindowEndDateTime = $bad.deliveryWindowStartDateTime
    { ConvertFrom-PilotOrder $bad $cfg $references } | Should -Throw '*window must end after*'
  }
  It 'fails closed when a stop does not fit the TMW display fields' {
    $tooLong = $canonical | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tooLong.stops[0].address1 = '12345678901234567890123456789012345678901'
    { New-TmwOrderCommand $tooLong $cfg } | Should -Throw '*address1 must fit TMW varchar(40)*'
  }
}

Describe 'poll window and filtering' {
  It 'refuses a one-day window that can drop straddling loads' {
    { Receive-PilotOrders ([pscustomobject]@{}) $session 1 } | Should -Throw
  }
  It 'stages only good loads: Scheduled, a delivery window, active items all with gallons' {
    $item = [pscustomobject]@{ dispatchOrderItemId = 7; gallons = 7500; isDeleted = $false }
    $win = @{ deliveryWindowStartDateTime = '2026-09-28T12:00:00'; deliveryWindowEndDateTime = '2026-09-28T16:00:00' }
    $w = $win + @{ dispatchOrderItems = @($item) }
    $records = @(
      [pscustomobject](@{ dispatchOrderId = 1; dispatchOrderStatusTypeId = 2 } + $w)
      [pscustomobject](@{ dispatchOrderId = 2; dispatchOrderStatusTypeId = 4; dispatchOrderStatusTypeName = 'Kiosked' } + $w)
      [pscustomobject](@{ dispatchOrderId = 3; dispatchOrderStatusTypeId = 1 } + $w)
      [pscustomobject]@{ dispatchOrderId = 4; dispatchOrderStatusTypeId = 2; dispatchOrderItems = @($item) }
      [pscustomobject]@{ dispatchOrderId = 5; dispatchOrderStatusTypeId = 2; deliveryWindowStartDateTime = '2026-09-28T16:00:00'; deliveryWindowEndDateTime = '2026-09-28T12:00:00'; dispatchOrderItems = @($item) }
      [pscustomobject](@{ dispatchOrderId = 6; dispatchOrderStatusTypeId = 2 } + $win + @{ dispatchOrderItems = @() })
      [pscustomobject](@{ dispatchOrderId = 7; dispatchOrderStatusTypeId = 2 } + $win + @{ dispatchOrderItems = @([pscustomobject]@{ dispatchOrderItemId = 8; gallons = 0; isDeleted = $false }) })
    )
    @(Select-PilotOrdersToProcess $records $cfg).dispatchOrderId | Should -Be @(1)
    @($records | ForEach-Object { Get-PilotOrderSkipReason $_ @(2) }) | Should -Be @(
      'status 4 Kiosked', 'status 1', 'no delivery window', 'delivery window ends before it starts', 'no active items', 'no gallons on item 8')
    $cfg2 = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cfg2.poll.include_statuses = @(1, 2)
    @(Select-PilotOrdersToProcess $records $cfg2).dispatchOrderId | Should -Be @(1, 3)
  }
  It 'reads no reference data when every order is Kiosked' {
      $kiosked = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $kiosked.dispatchOrderStatusTypeId = 4
      Mock Get-PilotOrder -ModuleName PilotCarrierIntegration { @($kiosked) }
      Mock Get-PilotReferenceData -ModuleName PilotCarrierIntegration { $references }
      @(Receive-PilotOrders $cfg $session 30).Count | Should -Be 0
      Should -Invoke Get-PilotReferenceData -ModuleName PilotCarrierIntegration -Times 0
  }
  It 'skips a bad order without blocking a good one, and logs its reason once' {
      $bad = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $bad.dispatchOrderId = 999
      $bad.dispatchOrderItems[0].gallons = 0
      $cached = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $cached | Add-Member -NotePropertyName directory -NotePropertyValue (Join-Path $TestDrive 'skip-job') -Force
      Mock Get-PilotOrder -ModuleName PilotCarrierIntegration { @($bad, $rawOrder) }
      Mock Get-PilotReferenceData -ModuleName PilotCarrierIntegration { $references }
      Mock Write-Log -ModuleName PilotCarrierIntegration
      $received = @(Receive-PilotOrders $cached $session 30)
      $received.Count | Should -Be 1
      $received[0].pilotOrderId | Should -Be '10877997'
      @(Receive-PilotOrders $cached $session 30).Count | Should -Be 1
      Should -Invoke Write-Log -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter { $Message -like 'Skipped: 999, no gallons on item *' }
      (Get-Content (Join-Path $TestDrive 'skip-job/cache/999.json') -Raw | ConvertFrom-Json).state | Should -Be 'skipped'
  }
  It 'passes over an order already staged before reading anything else' {
      $cached = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $cached | Add-Member -NotePropertyName directory -NotePropertyValue (Join-Path $TestDrive 'staged-job') -Force
      New-Item -ItemType Directory (Join-Path $TestDrive 'staged-job/cache') -Force | Out-Null
      @{ dispatch_order_id = '10877997'; state = 'staged'; tmw_order = '10686484'; updated_at = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'staged-job/cache/10877997.json')
      Mock Get-PilotOrder -ModuleName PilotCarrierIntegration { @($rawOrder) }
      Mock Get-PilotReferenceData -ModuleName PilotCarrierIntegration { $references }
      Mock Write-Log -ModuleName PilotCarrierIntegration
      @(Receive-PilotOrders $cached $session 30).Count | Should -Be 0
      Should -Invoke Get-PilotReferenceData -ModuleName PilotCarrierIntegration -Times 0
      Should -Invoke Write-Log -ModuleName PilotCarrierIntegration -ParameterFilter { $Message -eq 'Pilot  : 1 orders read, 1 already staged, 0 skipped, 0 to stage' }
  }
}

Describe 'direct TMW DataExchange staging' {
  BeforeAll {
    $script:writeCfg = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $script:archive = New-DxArchivePlan $canonical $writeCfg ([datetime]'2026-08-01T12:00:00')
    $script:laterArchive = New-DxArchivePlan $canonical $writeCfg ([datetime]'2026-08-01T13:00:00')
    $changed = $canonical | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    foreach ($stop in @($changed.stops)) { $stop.freight[0].quantity = [decimal]$stop.freight[0].quantity + 1 }
    $script:changedArchive = New-DxArchivePlan $changed $writeCfg ([datetime]'2026-08-01T13:00:00')
    $script:command = New-TmwOrderCommand $canonical $writeCfg -Now ([datetime]'2026-08-01T12:00:00')
    $multiRaw = $rawOrder | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second = $multiRaw.dispatchOrderItems[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second.dispatchOrderItemId = 11888002
    $second.productName = 'REGULAR UNLEADED'
    $multiRaw.dispatchOrderItems = @($multiRaw.dispatchOrderItems[0], $second)
    $script:multiCommand = New-TmwOrderCommand (ConvertFrom-PilotOrder $multiRaw $writeCfg $references) $writeCfg
  }
  It 'builds a complete version-39 archive with raw mapping values' {
    $archive.sourceName | Should -Match '^PILOTAPI\.10877997\.[0-9a-f]{64}$'
    @($archive.rows).Count | Should -Be 30
    @($archive.rows | Where-Object { $_.fields.dx_field001.Trim() -eq '03' }).Count | Should -Be 2
    @($archive.rows | Where-Object { $_.fields.dx_field001.Trim() -eq '04' }).Count | Should -Be 2
    $freight = @($archive.rows | Where-Object { $_.fields.dx_field001.Trim() -eq '04' })[0]
    $freight.fields.dx_field013.Trim() | Should -Be 'ULSD #2 W/ 99% BIO'
    $freight.fields.dx_field014 | Should -Be '        '
    $pickupAddress = @($archive.rows | Where-Object { $_.fields.dx_field001.Trim() -eq '06' -and $_.fields.dx_field003.Trim() -eq 'ST' })[0]
    $pickupAddress.fields.dx_field005.Trim() | Should -Be '100 TERMINAL WAY'
    $pickupAddress.fields.dx_field006.Trim() | Should -Be 'GATE 2'
    $supplierId = @($archive.rows | Where-Object {
      $_.stopIndex -eq 1 -and $_.freightIndex -eq 1 -and $_.fields.dx_field003.Trim() -eq 'SID'
    })[0]
    $supplierId.fields.dx_field004.Trim() | Should -Be '10180'
    $supplierName = @($archive.rows | Where-Object {
      $_.stopIndex -eq 1 -and $_.freightIndex -eq 1 -and $_.fields.dx_field003.Trim() -eq 'SUN'
    })[0]
    $supplierName.fields.dx_field004.Trim() | Should -Be 'CARGILL'
    @($archive.rows | Where-Object {
      $_.fields.dx_field001.Trim() -eq '06' -and $_.fields.dx_field003.Trim() -eq 'SU'
    }).fields.dx_field004.Trim() | Should -Be @('CARGILL')
    @($archive.rows | Where-Object {
      $_.stopIndex -eq 0 -and $_.fields.dx_field001.Trim() -eq '05' -and
      $_.fields.dx_field003.Trim() -eq 'SUP'
    }).fields.dx_field004.Trim() | Should -Be @('CARGILL')
    @($archive.rows | Where-Object {
      $_.stopIndex -gt 0 -and $_.freightIndex -gt 0 -and
      $_.fields.dx_field003.Trim() -eq 'PO'
    }).fields.dx_field004.Trim() | Should -Be @('11888001', '11888001')
    @($archive.rows | Where-Object { $_.fields.dx_field003.Trim() -eq 'SCA' }).fields.dx_field004.Trim() |
      Should -Contain 'SCAC'
    @($archive.rows | Where-Object { $_.fields.dx_field003.Trim() -eq '_R1' }).fields.dx_field004.Trim() |
      Should -Contain 'DIV'
  }
  It 'fingerprints business payloads independently of intake time' {
    $archive.fingerprint | Should -Match '^[0-9a-f]{64}$'
    $laterArchive.fingerprint | Should -Be $archive.fingerprint
    $laterArchive.sourceName | Should -Be $archive.sourceName
    $changedArchive.fingerprint | Should -Not -Be $archive.fingerprint
  }
  It 'uses one transaction, one order lock, and only vendor DX procedures' {
    $command.sql | Should -Match 'begin transaction'
    $command.sql | Should -Match 'sp_getapplock'
    $command.sql | Should -Match 'dx_add_neworder_stop'
    $multiCommand.sql | Should -Match 'dx_add_neworder_freight_to_stop'
    $command.sql | Should -Match 'dx_create_order_from_stops'
    $command.sql | Should -Match 'dx_add_refnumber_to_order'
    $command.sql | Should -Match 'dx_add_refnumber_to_freight'
    $command.sql | Should -Match "'SCA', @scac"
    $command.sql | Should -Match "'Y', @division"
    $command.sql | Should -Not -Match '(?im)^\s*(create|alter|drop)\s+(table|proc|view|function|trigger)'
  }
  It 'requires EDI/PILOT/state 10 before commit' {
    $command.sql | Should -Match "ord_order_source = 'EDI'"
    $command.sql | Should -Match 'ord_editradingpartner = @partner'
    $command.sql | Should -Match 'ord_edistate = 10'
    $command.sql | Should -Match 'ord_revtype1 = @division'
    $command.sql | Should -Match "ref_type = 'SCA' and ref_number = @scac"
    $command.sql | Should -Match "case when @commit = 1 then 'CREATED' else 'VALIDATED'"
  }
  It 'uses valid placeholders internally and keeps raw company values in the archive mapping rows' {
    $command.sql | Should -Match "dx_add_neworder_stop 'N', @mv, 1, 'LLD', 'UNKNOWN'"
    $command.sql | Should -Match "cmp_id = 'UNKNOWN'"
    $command.sql | Should -Match 'dx_movenumber'
    $command.sql | Should -Match '@partner, @supplier, @ordnum output'
    @($command.parameters | Where-Object name -eq '@supplier').value | Should -Be 'UNKNOWN'
    $command.sql | Should -Match 'supplier must remain UNKNOWN for DX mapping'
    $command.sql | Should -Not -Match '@tmwsup|set fgt_supplier'
    $command.sql | Should -Match "'SID', @supid1_1"
    $command.sql | Should -Match "'SUN', @supname1_1"
    $command.sql | Should -Match "'PO', @oid1_1"
    @($command.parameters.value) | Should -Contain '14673'
    @($archive.rows | Where-Object { $_.fields.dx_field001.Trim() -eq '06' }).fields.dx_field004.Trim() |
      Should -Contain 'EXAMPLE TERMINAL'
  }
  It 'populates the actual pending stops for the DataExchange screen' {
    $command.sql | Should -Match 'update s set cmp_name = @name1'
    $command.sql | Should -Match 'stp_address = @address1_1'
    $command.sql | Should -Match 'stp_city = @city_code1'
    $command.sql | Should -Match 'stp_departuredate = @late1'
    $command.sql | Should -Match 'stp_schdtlatest = @late1'
    $command.sql | Should -Match 'stp_timewindow = @window1'
    $command.sql | Should -Match 'stp_departuredate > s.stp_arrivaldate'
    $command.sql | Should -Match "s.stp_event = 'LUL' and rtrim\(s.stp_timewindow\) = 'Custom'"
    $command.sql | Should -Match 'created order has incomplete display stops or delivery windows'
    $command.sql | Should -Match 'rtrim\(cty_zip\) = rtrim\(@zip1\)'
    $command.sql | Should -Match 'select @city_code1 = coalesce'
    $command.sql | Should -Match "throw 50020, 'Pilot stop city is absent from TMW'"
    @($command.parameters.value) | Should -Contain '100 TERMINAL WAY'
    @($command.parameters.value) | Should -Contain 'KNOXVILLE'
    @($command.parameters | Where-Object name -eq '@window1').value | Should -Be ''
    @($command.parameters | Where-Object name -eq '@window2').value | Should -Be 'Custom'
    @($command.parameters | Where-Object name -eq '@remark').value |
      Should -Be 'PO: 10877997 WINDOW: 2300-0600'
  }
  It 'routes the created order to its division before accepting the transaction' {
    $command.sql | Should -Match "@source_date, 'DX', @billto"
    $command.sql | Should -Match 'set ord_revtype1 = @division, ord_booked_revtype1 = @division'
    $command.sql | Should -Match "rtrim\(ord_bookedby\) = 'DX'"
    $command.sql | Should -Match "throw 50023, 'could not route Pilot order to its division'"
  }
  It 'writes the DX archive in the same transaction' {
    $command.sql | Should -Match 'insert dbo.dx_Archive_header'
    $command.sql | Should -Match "@mv, '204', '', 'PILOTFEED'"
    $command.sql | Should -Match 'insert dbo.dx_Archive_detail'
    $command.sql | Should -Match 'DX archive detail count mismatch'
  }
  It 'is parameterized and does not embed Pilot data in SQL text' {
    $command.sql | Should -Not -Match '10877997|ULSD #2|14673|55979'
    @($command.parameters.value) | Should -Contain '10877997'
    @($command.parameters.value) | Should -Contain 'ULSD #2 W/ 99% BIO'
  }
  It 'drops an order already in TMW without touching it' {
    $command.sql | Should -Match 'r.ref_number = @pilot_id'
    $command.sql | Should -Match 'duplicate TMW orders exist for Pilot order ID'
    $command.sql | Should -Match "@replay_action varchar\(40\) = 'EXISTS'"
    $command.sql | Should -Not -Match 'REVIEW_'
    $command.sql | Should -Match '@requires_review requires_review'
    $command.sql | Should -Match 'partial Pilot order state exists'
  }
  It 'retries an order until it succeeds' {
    $script:retryCount = 0
    $result = Invoke-TmwRetry -MaxAttempts 3 -DelaySeconds 0 -Operation {
      $script:retryCount++
      if ($script:retryCount -lt 3) { throw 'temporary failure' }
      [pscustomobject]@{ ok = $true }
    }
    $result.ok | Should -BeTrue
    $result.attempts | Should -Be 3
  }
  It 'keeps the archive fingerprint through the formatter handoff, so a staged order stays unchanged' {
    $path = Join-Path $TestDrive 'orders.xml'
    Save-PilotOrderPlan -Data @($canonical) -Options @{ Path = $path }
    $back = @(Import-Clixml -LiteralPath $path)[0]
    $now = [datetime]'2026-08-01T12:00:00'
    (New-DxArchivePlan $back $cfg $now).fingerprint | Should -Be (New-DxArchivePlan $canonical $cfg $now).fingerprint
    (New-TmwOrderCommand $back $cfg -Now $now).sql | Should -Be (New-TmwOrderCommand $canonical $cfg -Now $now).sql
  }
}
}

Describe 'reference lists kept in the cache' {
  BeforeAll {
    Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  }
  It 'reads each list once, then again only for an id the kept copy lacks' {
    InModuleScope PilotCarrierIntegration {
      $dir = Join-Path $TestDrive 'refcache'
      Mock Write-Log
      Mock Get-PilotLocation { @([pscustomobject]@{ locationSystemId = 1; address1 = 'a' }) }
      Mock Get-PilotTerminal { @([pscustomobject]@{ terminalId = 10 }) }
      Mock Get-PilotContract { @([pscustomobject]@{ contractSystemId = 20 }) }
      $order = { param($loc) [pscustomobject]@{ dispatchOrderItems = @([pscustomobject]@{ locationSystemId = $loc; lineOfOperationsSystemId = 10; looSystemId = 20 }) } }
      $first = Get-PilotReferenceData ([pscustomobject]@{}) @(& $order 1) $dir
      $first.locations['1'].address1 | Should -Be 'a'
      $null = Get-PilotReferenceData ([pscustomobject]@{}) @(& $order 1) $dir
      Should -Invoke Get-PilotLocation -Times 1 -Exactly
      Should -Invoke Get-PilotTerminal -Times 1 -Exactly
      $null = Get-PilotReferenceData ([pscustomobject]@{}) @(& $order 2) $dir
      Should -Invoke Get-PilotLocation -Times 2 -Exactly
      Should -Invoke Get-PilotTerminal -Times 1 -Exactly
    }
  }
}

Describe 'cache lifetimes' {
  BeforeAll {
    Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  }
  It 'drops an order file older than keep_days, by the date inside it' {
    InModuleScope PilotCarrierIntegration {
      $job = Join-Path $TestDrive 'life-job'
      New-Item -ItemType Directory "$job/cache" -Force | Out-Null
      @{ dispatch_order_id = '1'; state = 'staged'; updated_at = [datetime]::UtcNow.AddDays(-8).ToString('o') } | ConvertTo-Json | Set-Content "$job/cache/1.json"
      @{ dispatch_order_id = '2'; state = 'staged'; updated_at = [datetime]::UtcNow.AddDays(-6).ToString('o') } | ConvertTo-Json | Set-Content "$job/cache/2.json"
      Mock Get-PilotOrder { @() }
      Mock Write-Log
      $null = Receive-PilotOrders ([pscustomobject]@{ directory = $job; poll = [pscustomobject]@{ window_days = 30 } }) ([pscustomobject]@{}) 30
      Test-Path "$job/cache/1.json" | Should -BeFalse
      Test-Path "$job/cache/2.json" | Should -BeTrue
    }
  }
  It 'drops a BOL cache file older than keep_days before planning, so a changed order can go again' {
    InModuleScope PilotCarrierIntegration {
      $dir = Join-Path $TestDrive 'bol-cache'
      New-Item -ItemType Directory $dir -Force | Out-Null
      @{ sent_at = [datetime]::UtcNow.AddDays(-8).ToString('o'); hash = 'x' } | ConvertTo-Json | Set-Content "$dir/1.json"
      @{ sent_at = [datetime]::UtcNow.AddDays(-1).ToString('o'); hash = 'y' } | ConvertTo-Json | Set-Content "$dir/2.json"
      Mock Write-Log
      Save-PilotBolPlan @() @{ Path = (Join-Path $TestDrive 'bol-out/plan.json'); Cache = $dir; KeepDays = 7 }
      Test-Path "$dir/1.json" | Should -BeFalse
      Test-Path "$dir/2.json" | Should -BeTrue
    }
  }
}

Describe 'the Pilot read window' {
  BeforeAll {
    Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  }
  It 'starts lookback_days before today and runs window_days from the start' {
    InModuleScope PilotCarrierIntegration {
      Mock Get-PilotOrder { @() }
      Mock Write-Log
      $null = Receive-PilotOrders ([pscustomobject]@{ poll = [pscustomobject]@{ window_days = 30; lookback_days = 7 } }) ([pscustomobject]@{}) 0
      Should -Invoke Get-PilotOrder -Times 1 -Exactly -ParameterFilter {
        $StartDate -eq [datetime]::Today.AddDays(-7) -and $EndDate -eq [datetime]::Today.AddDays(23)
      }
    }
  }
}
