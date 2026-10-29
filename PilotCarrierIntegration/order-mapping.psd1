@{
  SchemaVersion = 2
  Validators = @{
    nonblank = @{ kind = 'regex'; pattern = '\S' }
    gallons = @{ kind = 'positive_decimal' }
    scheduled = @{
      kind = 'window'; missing = 'no scheduled window'; invalid = 'invalid scheduled window'
      reversed = 'scheduled window ends before it starts'
    }
  }
  Order = @(
    @{ src = '$.order.dispatchOrderId'; dst = 'dx_create_order_from_stops.ord_refnum'; cast = 'string'
      checks = @(@{ use = 'nonblank'; message = 'no dispatchOrderId' }) }
    @{ src = '$.order.sourceSystemOrderId'; dst = 'dx_Archive_detail.dx_field004'; ref = 'SO'; cast = 'string' }
    @{ src = '$.order.scheduledStartDateTime'; dst = 'dx_add_neworder_stop.earlydate'; cast = 'datetime'; checks = @('scheduled') }
    @{ src = '$.order.scheduledEndDateTime'; dst = 'dx_add_neworder_stop.latedate'; cast = 'datetime' }
    @{ src = '$.create.billto'; dst = @('dx_create_order_from_stops.ord_billto_cmpid', 'dx_create_order_from_stops.orderby_cmpid'); cast = 'nullable_string' }
  )
  Freight = @(
    @{ src = '$.item.gallons'; dst = @('dx_add_neworder_stop.volume', 'dx_add_neworder_freight_to_stop.volume')
      checks = @(@{ use = 'gallons'; message = 'no gallons on item {0}' }) }
    @{ src = @('$.item.productCode', '$.item.wraProductDescription'); format = '{0} / {1}'
      dst = @('dx_add_neworder_stop.cmd_description', 'dx_add_neworder_freight_to_stop.cmd_description')
      checks = @(@{ use = 'nonblank'; src = '$.item.wraProductDescription'; message = 'no wraProductDescription on item {0}' }) }
    @{ src = '$.item.productCode'; dst = 'dx_Archive_detail.dx_field004'; ref = 'L06'; cast = 'string'
      checks = @(@{ use = 'nonblank'; message = 'no productCode on item {0}' }) }
    @{ src = '$.item.dispatchOrderItemId'; dst = @('dx_add_neworder_stop.fgt_refnum', 'dx_add_neworder_freight_to_stop.fgt_refnum'); cast = 'string'
      checks = @(@{ use = 'nonblank'; message = 'no dispatchOrderItemId on item {0}' }) }
    @{ src = '$.item.looSystemId'; dst = 'dx_add_refnumber_to_freight.fgt_refnum'; ref = 'SID'; default = 'UNKNOWN'; blank = $true; cast = 'string' }
    @{ src = '$.contract.contractName'; dst = 'dx_add_refnumber_to_freight.fgt_refnum'; ref = 'SUN'; phase = 'lookup'; default = 'NO SUPPLIER'; cast = 'string' }
  )
  Pickup = @(
    @{ src = '$.item.lineOfOperationsSystemId'; dst = 'dx_add_neworder_stop.stp_refnum'; default = 'UNKNOWN'; blank = $true; cast = 'string' }
    @{ src = '$.terminal.name'; dst = 'stops.cmp_name'; phase = 'lookup'; default = 'NO TERMINAL' }
    @{ src = '$.terminal.address'; dst = 'stops.stp_address'; phase = 'lookup' }
    @{ src = '$.terminal.address2'; dst = 'stops.stp_address2'; phase = 'lookup' }
    @{ src = '$.terminal.city'; dst = 'stops.stp_city'; phase = 'lookup' }
    @{ src = @('$.terminal.stateSystemCode', '$.terminal.state'); dst = 'stops.stp_state'; phase = 'lookup' }
    @{ src = '$.terminal.postalCode'; dst = 'stops.stp_zipcode'; phase = 'lookup' }
  )
  Delivery = @(
    @{ src = '$.item.locationSystemId'; dst = 'dx_add_neworder_stop.stp_refnum'; cast = 'string'
      checks = @(@{ use = 'nonblank'; message = 'no locationSystemId on item {0}' }) }
    @{ src = '$.location.description'; dst = 'stops.cmp_name'; phase = 'lookup'; default = 'NO LOCATION' }
    @{ src = '$.location.address1'; dst = 'stops.stp_address'; phase = 'lookup' }
    @{ src = '$.location.address2'; dst = 'stops.stp_address2'; phase = 'lookup' }
    @{ src = '$.location.city'; dst = 'stops.stp_city'; phase = 'lookup' }
    @{ src = '$.location.stateCode'; dst = 'stops.stp_state'; phase = 'lookup' }
    @{ src = '$.location.postalCode'; dst = 'stops.stp_zipcode'; phase = 'lookup' }
  )
}
