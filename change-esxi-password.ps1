#Read in old passwords, masked
$oldpw = read-host -prompt "Enter the current root password" -AsSecureString
$newpw = read-host -prompt "Enter the desired new root password" -AsSecureString
#Decrypting for actual use
$oldpw = [System.Runtime.InteropServices.marshal]::PtrToStringAuto([System.Runtime.InteropServices.marshal]::SecureStringToBSTR($oldpw))
$newpw = [System.Runtime.InteropServices.marshal]::PtrToStringAuto([System.Runtime.InteropServices.marshal]::SecureStringToBSTR($newpw))

#Get list of ESXi hosts
$vCenter = Read-host -prompt "Enter the vCenter hostname:"
write-host "Prompting for credentials and connecting to vCenter..."
connect-viserver -server $vCenter -Credential (Get-Credential)
$hosts = @()
write-host "Querying for ESXi hosts..."

Get-VMHost | Sort-Object | Where-Object {$_.ConnectionState -eq "Connected" -or $_.ConnectionState -eq "Maintenance"} | ForEach-Object { $hosts+= $_.Name }

Disconnect-VIServer -confirm:$false

#Connect to each ESXi host and change pw
foreach ($vmhost in $hosts) {
    write-host "Connecting to $vmhost..."
    connect-viserver -server $vmhost -user root -password "$oldpw"
    write-host "Changing root password on $vmhost..."
    Set-VMHostAccount -UserAccount root -password "$newpw"
    Disconnect-VIServer -confirm:$false
}
