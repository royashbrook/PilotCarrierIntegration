# DataAgent formatter: TMW completed freight -> Pilot BOL plan
param($Data, [hashtable] $Options)
& (Get-Module PilotCarrierIntegration) { param($d, $o) Save-PilotBolPlan -Data $d -Options $o } $Data $Options
