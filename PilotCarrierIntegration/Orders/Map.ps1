# The tables behind the order feed, data only: which Pilot lists fill in names and addresses, the checks a
# row can name, and the field map. Read.ps1 reads the lists, Translate.ps1 applies the map.

# Pilot's three reference lists, each its own endpoint: the item field that names a row, and the row's key.
$script:PilotReferenceLists = @(
  @{ name = 'location'; id = 'locationSystemId';         key = 'locationSystemId'; read = 'Get-PilotLocation' }
  @{ name = 'terminal'; id = 'lineOfOperationsSystemId'; key = 'terminalId';       read = 'Get-PilotTerminal' }
  @{ name = 'contract'; id = 'looSystemId';              key = 'contractSystemId'; read = 'Get-PilotContract' }
)

# The field map, one row per field of the order we build. Pilot's JSON is already an object here, so
# `src` is a path into the objects in hand: what Pilot sent (order, item, terminal, location, contract)
# and the settings (cfg). `dst` is the property it becomes on the order, pickup, delivery or freight
# object. The writer turns that object into the TMW calls; one property can land in several columns
# (gallons in two procedures and an archive row), so the TMW side stays in the writer and the README
# table. Several `src` paths take the first that is not blank, `format` joins them, `value` is a fixed
# value, and `default` fills a blank. A row with a `check` runs it on each `src` before anything else is
# read, in list order, and the first failure is the skip reason: the checked rows lead, so the top of
# the list is the required-fields table. A check is a regex the value must match or a script block.
# Blank is null, empty or whitespace. Values stay as Pilot sent them.
$script:PilotOrderChecks = @{
  required = '\S'
  positive = { param($v) $d = 0d; [decimal]::TryParse([string]$v, [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0 }
}

$script:PilotOrderMap = @(
  @{ src = 'order.dispatchOrderId';          dst = 'order.pilotOrderId';         check = 'required' }
  @{ src = 'item.gallons';                   dst = 'freight.quantity';           check = 'positive' }
  @{ src = 'item.dispatchOrderItemId';       dst = 'freight.pilotOrderItemId';   check = 'required' }
  @{ src = 'item.locationSystemId';          dst = 'delivery.locationCode';      check = 'required' }
  # what to lift (the code carries the octane) and the WRA product (which tank): "Diesel" alone covers DSL and DSL-AS
  @{ src = 'item.productCode', 'item.wraProductDescription'; format = '{0} / {1}'; dst = 'freight.commodityName'; check = 'required' }
  # the order; the stops take their window from these two
  @{ src = 'order.sourceSystemOrderId';      dst = 'order.pilotSourceOrderId' }
  @{ src = 'order.scheduledStartDateTime';   dst = 'order.deliveryWindowStart';  cast = 'datetime' }
  @{ src = 'order.scheduledEndDateTime';     dst = 'order.deliveryWindowEnd';    cast = 'datetime' }
  @{ src = 'cfg.create.billto';              dst = 'order.billto' }
  # the pickup: the terminal, which Pilot may pick late, so a blank one stages UNKNOWN
  @{ value = 'PU';                           dst = 'pickup.type' }
  @{ src = 'item.lineOfOperationsSystemId';  dst = 'pickup.locationCode';        default = 'UNKNOWN' }
  @{ src = 'terminal.name';                  dst = 'pickup.name';                default = 'NO TERMINAL' }
  @{ src = 'terminal.address';               dst = 'pickup.address1' }
  @{ src = 'terminal.address2';              dst = 'pickup.address2' }
  @{ src = 'terminal.city';                  dst = 'pickup.city' }
  @{ src = 'terminal.stateSystemCode', 'terminal.state'; dst = 'pickup.state' }
  @{ src = 'terminal.postalCode';            dst = 'pickup.zip' }
  # the delivery: the store
  @{ value = 'DR';                           dst = 'delivery.type' }
  @{ src = 'location.description';           dst = 'delivery.name';              default = 'NO LOCATION' }
  @{ src = 'location.address1';              dst = 'delivery.address1' }
  @{ src = 'location.address2';              dst = 'delivery.address2' }
  @{ src = 'location.city';                  dst = 'delivery.city' }
  @{ src = 'location.stateCode';             dst = 'delivery.state' }
  @{ src = 'location.postalCode';            dst = 'delivery.zip' }
  # the freight, one line per item; the supplier is the supply contract, which Pilot may also pick late
  @{ src = 'item.productCode';               dst = 'freight.productCode' }
  @{ src = 'item.looSystemId';               dst = 'freight.supplierContractId'; default = 'UNKNOWN' }
  @{ src = 'contract.contractName';          dst = 'freight.supplierName';       default = 'NO SUPPLIER' }
)
