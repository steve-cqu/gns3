@{
    RootModule        = 'NetCompat.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '5d0c6b8e-3f0a-4f57-9d0e-7a3c2b1e9f41'
    Description       = 'Emulates the Windows networking cmdlets (NetAdapter, NetTCPIP) on Linux, for the GNS3 PC node.'
    PowerShellVersion = '7.4'
    FormatsToProcess  = @('NetCompat.format.ps1xml')
    FunctionsToExport = @(
        'Get-NetAdapter'
        'Get-NetIPAddress'
        'New-NetIPAddress'
        'Remove-NetIPAddress'
        'Test-NetConnection'
        'Get-NetNeighbor'
        'Get-NetIPConfiguration'
        'ping'
        'ipconfig'
        'Get-NetRoute'
        'New-NetRoute'
        'Set-NetRoute'
        'Remove-NetRoute'
        'Get-Service'
        'Start-Service'
        'Stop-Service'
        'Restart-Service'
        'tracert'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
