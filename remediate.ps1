#region connection
$tenantId = "REPLACE-WITH-YOUR-TENANT-ID"
$clientId = "REPLACE-WITH-YOUR-CLIENT-ID"
$clientSecret = "REPLACE-WITH-YOUR-CLIENT-SECRET"

#Start-Transcript -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AdminGroupRemediation-Remediate.log" -Append

$autoCreateGroups = $false #Set to $true for DEV tenant to auto-create missing groups
$exitcode = 0 #default exit code 0, will be set to 1 if remediation actions were attempted but failed
$logMsg = @()

try {
    $productName = (Get-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\DigitalWorkplace" -Name "ProductName" -ErrorAction Stop).ProductName
} catch {
    $productName = $null
}

$clientGroupName = "Admin-$($ENV:COMPUTERNAME)"                         # Will be member of local administrators
$adminGroupName = "Admin-Windows-$($productName)"                       # Will be member of local administrators
$remoteGroupName = "Admin-Intune-RemoteAccess-$($productName)"           # Will be member of local Remote Desktop Users and Remote Management Users

if ($autoCreateGroups -eq $true) {
    Start-Transcript -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AdminGroupRemediation-Remediate.log" -Append

    $clientGroupName = "DEV-Admin-$($ENV:COMPUTERNAME)"
    $adminGroupName = "DEV-Admin-Windows-$($productName)"
    $remoteGroupName = "DEV-Admin-Intune-RemoteAccess-$($productName)"
}
#endregion

#region main
$body = @{
    grant_type    = "client_credentials"
    scope         = "https://graph.microsoft.com/.default"
    client_id     = $clientId
    client_secret = $clientSecret
}

try {
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body
    $accessToken = $tokenResponse.access_token

    if ([string]::IsNullOrEmpty($accessToken)) {
        $logMsg += "Access token is empty. Check your credentials and permissions." 
        return
    }
    else {
        $logMsg += "Access token acquired." 
    }
} catch {
    $logMsg += "Error during token request:" 
    $_ | Format-List -Force
    return
}

Add-Type -AssemblyName System.Web

$headers = @{
    Authorization = "Bearer $accessToken"
}

if (-not (Test-Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement")) {
    New-Item -Path "HKLM:\SOFTWARE\COMPANY\" -Name "WindowsGroupManagement" -Force | Out-Null
}

### Client Local Admin
$logMsg += "Adding Client group '$clientGroupName' from Entra ID to local group..."
$ClientgraphUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($clientGroupName)'"

try {
    $clientGroupInfo = Invoke-RestMethod -Uri $ClientgraphUrl -Headers $headers -Method Get
    if ($clientGroupInfo.value.Count -eq 0) {
        $logMsg += "No group found with displayName '$($clientGroupName)'." 
    } else {
        $logMsg += "Group(s) found: $($clientGroupInfo.value | Select-Object displayName, id, securityIdentifier)"
    }
} catch {
    $logMsg += "Error during Graph API request:" 
    $_ | Format-List -Force
}

$clientGroupSID = $clientGroupInfo.value.securityIdentifier

if ($null -eq $clientGroupSID) {
    $logMsg += "Group SID is empty...Waiting for next schedule"
    $logMsgOut = $logMsg -join "`n"
    Write-Output "$logMsgOut"
} else {
    $clientGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-544"
    $ClientGroupExists = $clientGroupMembers | Where-Object { $_.Name -eq $clientGroupSID }

    if ($ClientGroupExists) {
        $logMsg += "$($clientGroupName) is a member of 'Administratoren'."
    } else {
        $logMsg += "$($clientGroupName) is NOT a member of 'Administratoren'."
        try {
            if ($null -ne $clientGroupSID) {
                $logMsg += "Adding $($clientGroupName) group to local admins"
                Add-LocalGroupMember -SID "S-1-5-32-544" -Member $clientGroupSID

                $clientGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-544"
                $ClientGroupExists = $clientGroupMembers | Where-Object { $_.Name -eq $clientGroupSID }

                if ($ClientGroupExists) {
                    $logMsg += "OK"
                    New-Item -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\" -Name "Administrators" -Force | Out-Null
                    New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Administrators" -Name "DisplayName" -PropertyType "String" -Value $clientGroupInfo.value.displayName -Force
                    New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Administrators" -Name "ObjectID" -PropertyType "String" -Value $clientGroupInfo.value.id -Force
                    New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Administrators" -Name "SID" -PropertyType "String" -Value $clientGroupInfo.value.securityIdentifier -Force
                } else {
                    $logMsg += "NOK"
                }
            } else {
                $logMsg += "Client group SID is null, cannot add to local admins"
            }
        }
        catch {
            $logMsg += "Failed to add $($clientGroupName) to local admins"
            $logMsgOut = $logMsg -join "`n"
            Write-Output "$logMsgOut"
            $exitcode = 1
        }
    }
}

if ($null -ne $productName) {
    ### ProductBundle Local Admin
    $logMsg += "Adding ProductBundle group '$adminGroupName' from Entra ID to local group..."
    $ProductgraphUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($adminGroupName)'"

    try {
        $productGroupInfo = Invoke-RestMethod -Uri $ProductgraphUrl -Headers $headers -Method Get
        if ($productGroupInfo.value.Count -eq 0) {
            $logMsg += "No group found with displayName '$($adminGroupName)'." 
        } else {
            $logMsg += "Group(s) found: $($productGroupInfo.value | Select-Object displayName, id, securityIdentifier)"
        }
    } catch {
        $logMsg += "Error during Graph API request:" 
        $_ | Format-List -Force
    }

    $productGroupSID = $productGroupInfo.value.securityIdentifier

    if ($null -eq $productGroupSID) {
        $logMsg += "Group SID is empty...Waiting for next schedule"
        $logMsgOut = $logMsg -join "`n"
        Write-Output "$logMsgOut"
    } else {

        $productGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-544"
        $ProductGroupExists = $productGroupMembers | Where-Object { $_.Name -eq $productGroupSID }

        if ($ProductGroupExists) {
            $logMsg += "$($adminGroupName) is a member of 'Administratoren'."
        } else {
            $logMsg += "$($adminGroupName) is NOT a member of 'Administratoren'."
            try {
                if ($null -ne $productGroupSID) {
                    $logMsg += "Adding $($adminGroupName) group to local admins"
                    Add-LocalGroupMember -SID "S-1-5-32-544" -Member $productGroupSID

                    $productGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-544"
                    $ProductGroupExists = $productGroupMembers | Where-Object { $_.Name -eq $productGroupSID }

                    if ($ProductGroupExists) {
                        $logMsg += "OK"
                        New-Item -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\" -Name "PBAdministrators" -Force | Out-Null
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\PBAdministrators" -Name "DisplayName" -PropertyType "String" -Value $productGroupInfo.value.displayName -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\PBAdministrators" -Name "ObjectID" -PropertyType "String" -Value $productGroupInfo.value.id -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\PBAdministrators" -Name "SID" -PropertyType "String" -Value $productGroupInfo.value.securityIdentifier -Force
                    } else {
                        $logMsg += "NOK"
                    }
                } else {
                    $logMsg += "Product group SID is null, cannot add to local admins"
                }
            }
            catch {
                $logMsg += "Failed to add $($adminGroupName) to local admins"
                $logMsgOut = $logMsg -join "`n"
                Write-Output "$logMsgOut"
                $exitcode = 1
            }
        }
    }

    ### ProductBundle Remote Access
    $logMsg += "Adding Remote Access group '$remoteGroupName' from Entra ID to local group..."
    $RemoteAccessGraphUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($remoteGroupName)'"

    try {
        $RemoteAccessGroupInfo = Invoke-RestMethod -Uri $RemoteAccessGraphUrl -Headers $headers -Method Get
        if ($RemoteAccessGroupInfo.value.Count -eq 0) {
            $logMsg += "No group found with displayName '$($remoteGroupName)'." 
        } else {
            $logMsg += "Group(s) found: $($RemoteAccessGroupInfo.value | Select-Object displayName, id, securityIdentifier)"
        }
    } catch {
        $logMsg += "Error during Graph API request:" 
        $_ | Format-List -Force
    }

    $RemoteAccessGroupSID = $RemoteAccessGroupInfo.value.securityIdentifier

    if ($null -eq $RemoteAccessGroupSID) {
        $logMsg += "Group SID is empty...Waiting for next schedule"
        $logMsgOut = $logMsg -join "`n"
        Write-Output "$logMsgOut" 
    } else {

        $RemoteAccessGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-555"
        $RemoteAccessGroupExists = $RemoteAccessGroupMembers | Where-Object { $_.Name -eq $RemoteAccessGroupSID }

        if ($RemoteAccessGroupExists) {
            $logMsg += "$($remoteGroupName) is a member of 'Remote Desktop Users'."
        } else {
            $logMsg += "$($remoteGroupName) is NOT a member of 'Remote Desktop Users'."
            try {
                if ($null -ne $RemoteAccessGroupSID) {
                    $logMsg += "Adding $($remoteGroupName) group to local Remote Desktop Users"
                    Add-LocalGroupMember -SID "S-1-5-32-555" -Member $RemoteAccessGroupSID

                    $RemoteAccessGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-555"
                    $RemoteAccessGroupExists = $RemoteAccessGroupMembers | Where-Object { $_.Name -eq $RemoteAccessGroupSID }

                    if ($RemoteAccessGroupExists) {
                        $logMsg += "OK"
                        New-Item -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\" -Name "Remote Desktop Users" -Force | Out-Null
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Desktop Users" -Name "DisplayName" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.displayName -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Desktop Users" -Name "ObjectID" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.id -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Desktop Users" -Name "SID" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.securityIdentifier -Force
                    } else {
                        $logMsg += "NOK"
                    }
                } else {
                    $logMsg += "Remote Access group SID is null, cannot add to local Remote Desktop Users"
                }
            }
            catch {
                $logMsg += "Failed to add $($remoteGroupName) to Remote Desktop Users"
                $logMsgOut = $logMsg -join "`n"
                Write-Output "$logMsgOut"
                $exitcode = 1
            }
        }

        $RemoteMgmtGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-580"
        $RemoteMgmtGroupExists = $RemoteMgmtGroupMembers | Where-Object { $_.Name -eq $RemoteAccessGroupSID }

        if ($RemoteMgmtGroupExists) {
            $logMsg += "$($remoteGroupName) is a member of 'Remote Management Users'."
        } else {
            $logMsg += "$($remoteGroupName) is NOT a member of 'Remote Management Users'."
            try {
                if ($null -ne $RemoteAccessGroupSID) {
                    $logMsg += "Adding $($remoteGroupName) group to local Remote Management Users"
                    Add-LocalGroupMember -SID "S-1-5-32-580" -Member $RemoteAccessGroupSID

                    $RemoteMgmtGroupMembers = Get-LocalGroupMember -SID "S-1-5-32-580"
                    $RemoteMgmtGroupExists = $RemoteMgmtGroupMembers | Where-Object { $_.Name -eq $RemoteAccessGroupSID }

                    if ($RemoteMgmtGroupExists) {
                        $logMsg += "OK"
                        New-Item -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\" -Name "Remote Management Users" -Force | Out-Null
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Management Users" -Name "DisplayName" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.displayName -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Management Users" -Name "ObjectID" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.id -Force
                        New-ItemProperty -Path "HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\Remote Management Users" -Name "SID" -PropertyType "String" -Value $RemoteAccessGroupInfo.value.securityIdentifier -Force
                    } else {
                        $logMsg += "NOK"
                    }
                } else {
                    $logMsg += "Remote Access group SID is null, cannot add to local Remote Management Users"
                }
                }
            catch {
                $logMsg += "Failed to add $($remoteGroupName) to Remote Management Users"
                $logMsgOut = $logMsg -join "`n"
                Write-Output "$logMsgOut"
                $exitcode = 1
            }
        }
    }
} else {
    $logMsg += "Policy for product bundle name not applied, skipping local admin productbundlegroup management"
}
#endregion

#region remediation output
$logMsgOut = $logMsg -join "`n"
if ($exitcode -eq 0) { Write-Output "OK" } else { Write-Output "$logMsgOut" }
if ($autoCreateGroups -eq $true) { Stop-Transcript | Out-Null }
exit $exitcode
#endregion

#Stop-Transcript