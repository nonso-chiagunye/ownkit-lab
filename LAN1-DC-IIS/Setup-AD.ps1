# Import required module
Import-Module ActiveDirectory

# Configuration
$DomainName = "ownkit.com"
$NetBIOSName = "OWNKIT"
$CSVPath = "C:\new_users&groups.csv"
$DefaultPassword = "P@ssw0rd123"  # Change in production for security
$SafeModePassword = ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force
$ServerIP = "192.168.1.10"  # Static IP of the server
$NewHostName = "DC01"  # Desired hostname for the domain controller

# Step 1: Change the server hostname
$currentHostName = (Get-ComputerInfo).WindowsProductName
if ($currentHostName -ne $NewHostName) {
    Rename-Computer -NewName $NewHostName -Force
    Write-Host "Hostname changed to $NewHostName. Rebooting..."
    Restart-Computer -Force
    # Script will stop here; re-run after reboot or use a scheduled task
    Start-Sleep -Seconds 60
}

# Step 2: Set static IP and DNS
Get-NetAdapter | Set-NetIPAddress -IPAddress $ServerIP -PrefixLength 24
Set-DnsClientServerAddress -InterfaceAlias (Get-NetAdapter).Name -ServerAddresses $ServerIP

# Step 3: Install AD DS and DNS roles
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

# Step 4: Promote server to domain controller
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBIOSName `
    -ForestMode WinThreshold `
    -DomainMode WinThreshold `
    -InstallDns `
    -SafeModeAdministratorPassword $SafeModePassword `
    -Force `
    -NoRebootOnCompletion

# Reboot server to apply changes
Restart-Computer -Force

# Step 5: Wait for reboot (script must be re-run after reboot or use a scheduled task)
Start-Sleep -Seconds 60  # Wait for system to stabilize

# Step 6: Import CSV file
$Users = Import-Csv -Path $CSVPath

# Step 7: Create OUs based on unique Locations
$Locations = $Users | Select-Object -Property Location -Unique
foreach ($Location in $Locations.Location) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Location'")) {
        New-ADOrganizationalUnit -Name $Location -Path "DC=$($DomainName.Replace('.',',DC='))" -ProtectedFromAccidentalDeletion $false
        Write-Host "Created OU: $Location"
    }
}

# Step 8: Create Security Groups based on unique Departments
$Departments = $Users | Select-Object -Property Department -Unique
foreach ($Department in $Departments.Department) {
    if (-not (Get-ADGroup -Filter "Name -eq '$Department'")) {
        New-ADGroup -Name $Department -GroupScope Global -GroupCategory Security -Path "DC=$($DomainName.Replace('.',',DC='))"
        Write-Host "Created Group: $Department"
    }
}

# Step 9: Create Users and assign to OUs and Groups
foreach ($User in $Users) {
    $FirstName = $User.First_Name
    $LastName = $User.Last_Name
    $SamAccountName = "$FirstName$LastName"
    $UserPrincipalName = "$SamAccountName@$DomainName"
    $Email = "$FirstName$LastName@$DomainName"
    $OUPath = "OU=$($User.Location),DC=$($DomainName.Replace('.',',DC='))"
    $FullName = "$FirstName $LastName"
    
    # Check if user already exists
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'")) {
        New-ADUser `
            -SamAccountName $SamAccountName `
            -UserPrincipalName $UserPrincipalName `
            -Name $FullName `
            -GivenName $FirstName `
            -Surname $LastName `
            -EmailAddress $Email `
            -Path $OUPath `
            -AccountPassword (ConvertTo-SecureString $DefaultPassword -AsPlainText -Force) `
            -Enabled $true `
            -ChangePasswordAtLogon $false
        Write-Host "Created User: $SamAccountName in OU: $($User.Location)"
        
        # Add user to Department group
        Add-ADGroupMember -Identity $User.Department -Members $SamAccountName
        Write-Host "Added $SamAccountName to Group: $($User.Department)"
    }
}

# Step 10: Verify setup
Write-Host "Verifying AD setup..."
Get-ADOrganizationalUnit -Filter * | Format-Table Name, DistinguishedName -AutoSize
Get-ADGroup -Filter * | Format-Table Name, GroupCategory, GroupScope -AutoSize
Get-ADUser -Filter * | Format-Table SamAccountName, UserPrincipalName, Enabled -AutoSize