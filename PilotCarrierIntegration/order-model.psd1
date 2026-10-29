# Internal model defaults and compatibility with the original mapping format.
@{
  Order = @(
    @{ destination = 'pilotOrderId'; source = 'record.dispatchOrderId'; cast = 'string' }
    @{ destination = 'pilotGuid'; source = 'record.dispatchOrderGuid' }
    @{ destination = 'pilotSourceOrderId'; source = 'record.sourceSystemOrderId'; cast = 'string' }
    @{ destination = 'pilotOrderItemIds'; source = 'context.itemIds' }
    @{ destination = 'contractSystemIds'; source = 'context.contractIds' }
    @{ destination = 'deliveryWindowStart'; source = 'record.scheduledStartDateTime'; cast = 'datetime' }
    @{ destination = 'deliveryWindowEnd'; source = 'record.scheduledEndDateTime'; cast = 'datetime' }
    @{ destination = 'billto'; source = 'cfg.create.billto'; cast = 'nullable_string' }
    @{ destination = 'bolNumber'; source = 'record.bolNumber' }
    @{ destination = 'kiosked'; source = 'context.kiosked' }
    @{ destination = 'stops'; source = 'context.stops' }
    @{ destination = 'raw'; source = 'record' }
    @{ destination = 'references'; source = 'context.references' }
  )
  Freight = @(
    @{ destination = 'freightNumber'; value = $null }
    @{ destination = 'uom'; value = 'GAL' }
    @{ destination = 'quantity'; source = 'item.gallons' }
    @{ destination = 'weight'; value = 0 }
    @{ destination = 'commodityName'; sources = @('item.productCode', 'item.wraProductDescription'); format = '{0} / {1}' }
    @{ destination = 'commodityCode'; source = 'item.productCode'; cast = 'string' }
    @{ destination = 'productCode'; source = 'item.productCode'; cast = 'string' }
    @{ destination = 'pilotOrderItemId'; source = 'item.dispatchOrderItemId'; cast = 'string' }
    @{ destination = 'pilotSourceItemId'; source = 'item.sourceSystemOrderItemId'; cast = 'string' }
    @{ destination = 'supplierContractId'; source = 'item.looSystemId'; default = 'UNKNOWN'; blank = $true; cast = 'string' }
    @{ destination = 'supplierName'; source = 'contract.contractName'; default = 'NO SUPPLIER'; cast = 'string' }
    @{ destination = 'supplierDescription'; source = @('contract.contractDescription', 'contract.contractName'); default = 'NO SUPPLIER'; cast = 'string' }
    @{ destination = 'productSystemId'; source = 'item.productSystemId' }
  )
  Pickup = @(
    @{ destination = 'stopNumber'; value = $null }
    @{ destination = 'type'; value = 'PU' }
    @{ destination = 'locationCode'; source = 'item.lineOfOperationsSystemId'; default = 'UNKNOWN'; blank = $true; cast = 'string' }
    @{ destination = 'name'; source = 'terminal.name'; default = 'NO TERMINAL' }
    @{ destination = 'address1'; source = 'terminal.address' }
    @{ destination = 'address2'; source = 'terminal.address2' }
    @{ destination = 'city'; source = 'terminal.city' }
    @{ destination = 'state'; source = @('terminal.stateSystemCode', 'terminal.state') }
    @{ destination = 'zip'; source = 'terminal.postalCode' }
    @{ destination = 'earliest'; source = 'context.start' }
    @{ destination = 'latest'; source = 'context.end' }
  )
  Delivery = @(
    @{ destination = 'stopNumber'; value = $null }
    @{ destination = 'type'; value = 'DR' }
    @{ destination = 'locationCode'; source = 'item.locationSystemId'; cast = 'string' }
    @{ destination = 'name'; source = 'location.description'; default = 'NO LOCATION' }
    @{ destination = 'address1'; source = 'location.address1' }
    @{ destination = 'address2'; source = 'location.address2' }
    @{ destination = 'city'; source = 'location.city' }
    @{ destination = 'state'; source = 'location.stateCode' }
    @{ destination = 'zip'; source = 'location.postalCode' }
    @{ destination = 'earliest'; source = 'context.start' }
    @{ destination = 'latest'; source = 'context.end' }
  )
  Validation = @{
    orderId = @{ field = 'Order.pilotOrderId'; kind = 'regex'; pattern = '\S'; message = 'no dispatchOrderId' }
    window = @{
      start = 'Order.deliveryWindowStart'; end = 'Order.deliveryWindowEnd'
      missing = 'no scheduled window'; invalid = 'invalid scheduled window'
      reversed = 'scheduled window ends before it starts'
    }
    quantity = @{ field = 'Freight.quantity'; kind = 'positive_decimal'; message = 'no gallons on item {0}' }
    requiredItem = @(
      @{ field = 'Freight.pilotOrderItemId'; kind = 'regex'; pattern = '\S'; message = 'no dispatchOrderItemId on item {0}' }
      @{ field = 'Delivery.locationCode'; kind = 'regex'; pattern = '\S'; message = 'no locationSystemId on item {0}' }
      @{ field = 'Freight.productCode'; kind = 'regex'; pattern = '\S'; message = 'no productCode on item {0}' }
      @{ field = 'Freight.commodityName'; part = 1; kind = 'regex'; pattern = '\S'; message = 'no wraProductDescription on item {0}' }
    )
  }
}
