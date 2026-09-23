# DataAgent formatter: keep the translated orders for the destination
param($Data, [hashtable] $Options)
& (Get-Module PilotCarrierIntegration) { param($d, $o) Save-PilotOrderPlan -Data $d -Options $o } $Data $Options
