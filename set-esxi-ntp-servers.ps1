param (
    # The esxi host to update
    [Parameter(Mandatory)]
    [string]
    $esxihost,

    # Root password used on this esxi host
    [Parameter()]
    [string]
    $rootpw = (Get-Item env:ESXI_ROOT_PW).Value,

    # Show info about the server being modified
    [Parameter()]
    [boolean]
    $details = $true
)

Write-host "Updating $esxihost..."
while ($global:DefaultVIServer.Count -ne 0) {
    Disconnect-VIServer -Confirm:$false
}
Connect-VIServer -Server $esxihost -User root -Password $rootpw | Out-Null
$hosts = Get-VMHost $esxihost | Get-VMHostNtpServer
if ($hosts.length -ne 0) {
    Remove-VMHostNtpServer -NtpServer $hosts -VMHost $esxihost -Confirm:$false
}
$ntpservers = @(
    'opdx-net01-prod.ops.puppetlabs.net',
    'pdx-net01-prod.ops.puppetlabs.net',
    'opdx-net02.service.puppetlabs.net',
    'pdx-net02-prod.ops.puppetlabs.net'
)
foreach ($ntpserver in $ntpservers) {
    Add-VmHostNtpServer -VMHost $esxihost -NtpServer $ntpserver | Out-Null
}
Get-VMHostFirewallException -VMHost $esxihost | Where-Object {$_.Name -eq "NTP client"} | Set-VMHostFirewallException -Enabled:$true |Out-Null
Get-VmHostService -VMHost $esxihost | Where-Object {$_.key -eq "ntpd"} | Start-VMHostService |Out-Null
Get-VmHostService -VMHost $esxihost | Where-Object {$_.key -eq "ntpd"} | Set-VMHostService -policy On |Out-Null
if ($details) {
    Write-host "Here are the current NTP servers, the service status, and the firewall rule:"
    Get-VMHost $esxihost | Get-VMHostNtpServer
    Get-VmHostService -VMHost $esxihost | Where-Object {$_.key -eq "ntpd"} |Format-Table
    Get-VMHostFirewallException -VMHost $esxihost | Where-Object {$_.Name -eq "NTP client"} |Select-Object -Property Name,Enabled,ServiceRunning |Format-Table
}
Disconnect-VIServer -Confirm:$false
