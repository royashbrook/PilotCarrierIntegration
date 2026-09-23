@{
  RootModule = 'PilotCarrierIntegration.psm1'
  ModuleVersion = '0.1.0'
  GUID = '393f77b8-b11b-4369-ad42-227e1ac0e79f'
  Author = 'Roy Ashbrook'
  CompanyName = 'ashbrook.io'
  Copyright = '(c) 2026 royashbrook. All rights reserved.'
  Description = 'Pilot carrier feeds as DataAgent runs, on PilotCarrierClient: BOL completions from TMW to Pilot.'
  PowerShellVersion = '7.4'
  RequiredModules = @(
    @{ ModuleName = 'DataAgent'; RequiredVersion = '0.5.0' }
    @{ ModuleName = 'PilotCarrierClient'; RequiredVersion = '1.0.0' }
    @{ ModuleName = 'Add-PrefixForLogging'; ModuleVersion = '1.0.0.2' }
  )
  FunctionsToExport = @('Invoke-PilotCarrierBols', 'New-PilotCarrierBolConfig')
  AliasesToExport = @()
  CmdletsToExport = @()
  VariablesToExport = @()
  PrivateData = @{
    PSData = @{
      Tags = @('pilot', 'carrier', 'tmw', 'bol', 'dataagent', 'logistics')
      LicenseUri = 'https://github.com/royashbrook/PilotCarrierIntegration/blob/main/LICENSE'
      ProjectUri = 'https://github.com/royashbrook/PilotCarrierIntegration'
    }
  }
}
