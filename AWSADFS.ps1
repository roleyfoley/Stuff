# --------------------------------------
# AWS SSC PowerShell Extension Module
# --------------------------------------
# MF2201 - 23/08/2016
#  This module is used to extend the AWS PowerShell module to include some SSC Specific requirements 
#  - AWS Account Profile Setup based on the AWS VPC setup
#  - Get all AWS VPC's and account numbers
#  - Get all the AWS Networks 

# Order of Operation 
# To make life happy commands should be run in the following order: 
# 1. Set-SSCAWSDefaults
# 2. Clear-SSCAWSCreds -NameFilter * 
# 3. Set-SSCAWSAuthSAML | Set-SSCAWSAuthManual
# 4. - If Requried - Get-SSCAWSVPCADFS 
# 5. - If Requried - Get-Get-AWSSubnets

# Sets the Basic AWS requirements - Proxy, Region
function Set-SSCAWSProxy {
    <#
    .SYNOPSIS 
    Sets the Proxy server for AWS to use within the SSC

    .DESCRIPTION 
    - Using predefined parameter values set the proxy 

    .PARAMETER SSCAWSProxy
    (Predefined)
    The hostname or IP address of the proxy server to use 

    .PARAMETER SSCAWSProxyPort
    (Predefined)
    The TCP port the proxy listens on for explicit connections

    .PARAMETER SSCAWSRegion
    (Predefined)
    Sets the AWS region - See: docs.aws.amazon.com/general/latest/gr/rande.html 

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    Param (
    [string]$SSCAWSProxy = 'proxy.dmz.ige',
    [string]$SSCAWSProxyPort = '8080'
    )    

    # Environement Setup - Import the Original AWS Powershell Module and Set Proxy Server
    Set-AWSProxy -Hostname $SSCAWSProxy -Port $SSCAWSProxyPort 

}

function Set-SSCAWSRegion { 
     <#
    .SYNOPSIS 
    Sets the AWS Region for the default auth profile 

    .DESCRIPTION 
    Sets the default AWS region and uses the first credential profile in the list to define the default  

    .PARAMETER SSCAWSRegion
    The AWS region code for our default region (Sydney) get-awsregion will provide all the codes

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    Param (
            [string]$SSCAWSRegion = 'ap-southeast-2'
    )

    # we have to use an actual profile instead of a dummy it appears
    [System.Collections.ArrayList]$CurrentCreds = Get-AWSCredential -ListProfileDetail
    $DefaultProfile = $CurrentCreds[0]

    Initialize-AWSDefaults -Region $SSCAWSRegion -ProfileName $DefaultProfile.ProfileName

}

# Removes AWS Credential Profiles
function Clear-SSCAWSCreds { 
    <#
    .SYNOPSIS 
    Cleans out the Credentials Profile Cache based on a filter of the profile name

    .DESCRIPTION 
    Removes credential profiles based on a wildcard filter

    .PARAMETER NameFilter
    A wildcard name for the server - set * for all 

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$NameFilter
    )
        [System.Collections.ArrayList]$CurrentCreds = (Get-AWSCredential -ListProfileDetail).ProfileName
        
        foreach ($Cred in $CurrentCreds) {
            if ($Cred -like "*$($NameFilter)*") {
                Remove-AWSCredentialProfile -ProfileName $Cred
            }
        }
}

# Gets the AWS Accounts you have access to and your role 
function Set-SSCAWSAuthSAML {
    <#
    .SYNOPSIS 
    Sets up SAML based authentication profiles for an account attempting to login to AWS 

    .DESCRIPTION 
    This commands uses an ADFS auth endpoint to generate an ADFS claim set for accessing the AWS Console. 
    By default the AWS ADFS auth profile generation will create an auth profile for every role that a user has for every account. Including multiple roles 

    Once the claimset has been authorised by AWS and a list of Authentication profiles have been created they are evaluated and the best role is picked for an account
    This runs on a highest privileges wins process using the Profile Tiers Dictonary to define this. 

    The Profile list only grants the highest role that a user has access to 

    .PARAMETER AuthEndPoint
    The ADSFS IDPInitited Login URL including the Relay party configuration for AWS 

    .PARAMETER ProfileTiers
    A dictonary of the roles that have been configured in ADFS and AWS for a user with a priority level for each role. 1 Being the best profile to use if it is available to a user

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    Param (
	    [string]$AuthEndpoint = "https://iauth.dis.gov.au/adfs/ls/IdpInitiatedSignOn.aspx?loginToRp=urn:amazon:webservices&whr=http://iauth.dis.gov.au/adfs/services/trust",
        [string]$AuthType = 'Kerberos',
        [string[]]$ProfileTiers = @{ 1 = "SSO_AWSRootAdmin"; 2 = "SSO_AWSAdmin"; 3 = "SSO_AWSSecurity"; 4 = "SSO_AWSNetwork"; 5 = "SSO_AWSBilling"; 6 = "SSO_AWSAgency"; 7 = "SSO_AWSMonitoring" } 
    )
    # Generate Authentication Details + Get your Profiles
    $AuthEndpointName = Set-AWSSamlEndpoint -Endpoint $AuthEndpoint -StoreAs "ADFS_iAuth" -AuthenticationType $AuthType
    Set-AWSSamlRoleProfile -EndpointName $AuthEndpointName -StoreAllRoles -Verbose -OutVariable $ProfilesAdded -ErrorVariable $ProfileErrors | Out-Null

    # Only use one role at a time 
    $AWSAccountProfiles = [array]$(Get-AWSCredential -ListProfileDetail ) | where-Object { $_.ProfileName -like "*:role/*"  } 
    
    # Find all of the accounts that you have a profile for 
    $Accounts = $AWSAccountProfiles | ForEach-Object { $_.Split(':')[0] } | Sort-Object -Unique 

    # Go through each account and find the highest access you have 
    foreach ( $Account in $Accounts ) {
        if ( !$TierLevel ) {
            $TierLevel = $ProfileTiers.Count
        }
        # Find the Profiles for each account 
        $ProfilesForAccount = $AWSAccountProfiles |  Where-Object { $_ -like "$($Account)*" }
        
        # Until we have 1 profile per account or we run out of Profile Tiers available remove lower tier profiles
        while ( ($ProfilesForAccount.Count) -ne 1 -or $TierLevel -gt ($ProfileTiers.Count) )  {
            # Remove AWS Credentials profile that you don't need 
            Remove-AWSCredentialProfile -ProfileName "$($Account):role/$($ProfileTiers.Get_Item($TierLevel))" 
            
            #See what we have left 
            $ProfilesForAccount = [array](Get-AWSCredential -ListProfiles) | where-Object { $_ -like "*:role/*"  } | Where-Object { $_ -like "$($Account)*" }
            
            # Move on to the next Tier 
            $TierLevel -- 
        }
    }

}

# Allows for manually added Access/Secret keys if ADFS is not supported 
function Set-SSCAWSAuthManual { 
    <#
    .SYNOPSIS 
    Creates a standardised manual Authentication Profile using AWS Secret Keys 

    .DESCRIPTION 
    This command allows you to add an authentication profile for an account that is not ADFS aware. It names the profile with a standard syntax that is used in other commands

    .PARAMETER Agency
    The Agency that the account hosts

    .PARAMETER Environment
    The application environement for the account 

    .PARAMETER SecretKey
    The Secret Key for a user in the AWS Account 

    .PARAMETER AccessKey
    The Access Key for a user in the AWS Account 

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)][string]$Agency,
        [Parameter(Mandatory=$true)][string]$Environment,
        [Parameter(Mandatory=$true)][string]$SecretKey,
        [Parameter(Mandatory=$true)][string]$AccessKey
    )    

    Set-AWSCredentials -AccessKey $AccessKey -SecretKey $SecretKey -StoreAs "Manual_$($Agency)-$($Environment)"

}

# Performs the basic setp for SSC happy AWS
function Set-SSCAWSEnv { 
    <#
    .SYNOPSIS 
    Perfoms the basic tasks required to access AWS within the SSC 

    .DESCRIPTION 
    Sets up, Proxy, Region and attempts SAML Auth to generate profiles 

    .PARAMETER ManualAuthOnly
    IF ADFS auth is not required then you can specify this switch which will skip the SAML process

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    None.  
    #>
    [CmdletBinding()]
    Param (
        [switch]$ManualAuthOnly
    )

    # Create the Basic paramters
    Set-SSCAWSProxy
    
    if ($ManualAuthOnly -ne $true ) {
        # Generate the SAML auth profiles 
        Set-SSCAWSAuthSAML
    }

    if ( (Get-AWSCredential -ListProfileDetail) -ne $null  ) {
        Set-SSCAWSRegion
    }
    else {
        write-error "Couldn't find any profiles to use - Please create manual auth profiles and try this again" -ErrorAction Stop
    }
}

# Grabs all VPC info for the accounts you have specified - If one cannot be found the account is still listed 
function Get-SSCAWSVPC {
    <#
    .SYNOPSIS 
    Provides a list of objects with details about an AWS VPC and its SSC Environment details based on a list of authentication profiles

    .DESCRIPTION 
    From the configured account profiles try and locate the AWS VPC/ACcount Details for each account in the profile 
        - Full Details will be loated if the VPC has the following Tags Assigned: 
        -- Agency - The name of the agency who owns the resources in the account
        -- Environement - The name of the application environment for the resources 

    .INPUTS 
    None. You cannont pipe objects 

    .OUTPUTS
    A List of all VPC's that have been located
    Objects Have the following Properties
    - VpcId = The AWS ID number for the VPC
    - VPCSubnet = The Private Subnet assigned to the VPC 
    - AccountId = The account ID that the VPC is hosted in 
    - AccountProfile = The Authentication Profile that can be used for this VPC 
    - Agency = The Agency who's resources are hosted in the VPC 
    - Environment = The Application environement for the resources hsoted in the VPC (Development/Preproduction/Production etc )

    #>
    [CmdletBinding()]
    Param()
    # Get all the Profiles that have been generated 
    $AWSAccountProfiles = [array]$(Get-AWSCredential -ListProfileDetail )
    $AWSAccountProfiles = $AWSAccountProfiles | where-Object { $_.ProfileName -like "*:role*" -or $_.ProfileName -like "Manual_*" }

    $AWSVPCDetails = New-Object System.Collections.ArrayList

    Foreach ( $AccountProfile in $AWSAccountProfiles ) {         
        # The ADFS profile shows the Account number in its name so lets split it up to find the Account Number 
        if ( $AccountProfile -like "*:role*") {
            $AWSAccountId = ($AccountProfile.Split('/')[0]).Split(':')[0]
        }
        else {
            $AWSAccountId = (((Get-IAMUser -ProfileName $AccountProfile.ProfileName ).Arn).TrimStart('arn:aws:iam::')).Split(':')[0]
        }

        # Find all VPC's with an Environement Tag Present - For some reason it has to be wiped to prevent duplicates
        $AWSVPCs = $null
        $AWSVPCs = Get-EC2Vpc -ProfileName $AccountProfile.ProfileName -Filter @( @{name='tag-key'; values="Environment"}) -ErrorAction SilentlyContinue 

        # If we Find VPC's with an environement tag they must be correct so lets get all the information 
        if ( $AWSVPCs -ne $null ) {
            foreach ( $AWSVPC in $AWSVPCs) { 
                    
                    $VPCInfo = New-object psobject -Property @{
                        VPCId           = $($AWSVPC.VpcId)
                        VPCSubnet       = $($AWSVPC.CidrBlock)
                        AccountId       = $($AWSAccountId)
                        AccountProfile  = $AccountProfile.ProfileName
                        Agency          = $(($AWSVPC.Tags | Where-Object { $_.Key -eq "Agency"}).Value) 
                        Environment     = $(($AWSVPC.Tags | Where-Object { $_.Key -eq "Environment"}).Value) 
                    }
                    [void]$AWSVPCDetails.Add($VPCInfo)
                
            }
        }

        # If we didn't find any VPC's we still want to know about the account but it wont contain everything 
        else {
            $AccountInfo = New-Object psobject -Property @{
                VPCId           = "NotFound"
                VPCSubnet       = "NotFound"
                AccountId       = $($AWSAccountId)
                AccountProfile = $AccountProfile.ProfileName
            }

            # If a profile has been created manually then we know the environement and agency tags as they have been set
            if ( $AccountProfile.ProfileName -like "Manual_*" ) {
                $AccountInfo | Add-Member -MemberType NoteProperty -Name Agency -Value $(($AccountProfile.ProfileName.TrimStart('Manual_')).Split('-')[0])
                $AccountInfo | Add-Member -MemberType NoteProperty -Name Environment -Value $(($AccountProfile.ProfileName.TrimStart('Manual_')).Split('-')[1])
            }
            # For accounts that have not found any VPC info at all
            else {
                $AccountInfo | Add-Member -MemberType NoteProperty -Name Agency -Value "NotFound"
                $AccountInfo | Add-Member -MemberType NoteProperty -Name Environment -Value "NotFound"
            }
            [void]$AWSVPCDetails.Add($AccountInfo)
        }
      }
   return $AWSVPCDetails 
}

# A filter based Subnet Search across all accounts/VPC
function Get-SSCAWSSubnets {
    <#
    .SYNOPSIS 
    Get a list of the Subnets found based on a filter using the VPC Details from Get-SSCAWSVPCADFS  

    .DESCRIPTION 
    From the VPC details generated in Get-SSCAWSVPCADFS provide a list of all the subnets in each VPC along with their name 
    A filter can be applied to look for specific ones 

    .INPUTS 
    None. You cannont pipe objects 

    .PARAMETER NetName
    A Filter for the Network Name you are looking for - defaults to * 

    .PARAMETER Agency
    A Filter for the Agency Networks you are looking for - defaults to * 

    .PARAMETER Environment
    A Filter for the Agency Networks you are looking for - defaults to * 

    .PARAMETER VPCInfo
    A System.Collections.ArrayList generated from Get-SSCAWSVPCADFS - Defaults to a variable called VPCBasicInfo

    .OUTPUTS
    A List of all VPC's that have been located
    Objects Have the following Properties
    - VpcId = The AWS ID number for the VPC
    - VPCSubnet = The Private Subnet assigned to the VPC 
    - AccountId = The account ID that the VPC is hosted in 
    - AccountProfile = The Authentication Profile that can be used for this VPC 
    - Agency = The Agency who's resources are hosted in the VPC 
    - Environment = The Application environement for the resources hsoted in the VPC (Development/Preproduction/Production etc )

    #>
    [CmdletBinding()]
    param
    (
        [string]$NetName = "*",
        [string]$Agency = "*",
        [string]$Environment = "*",
        $VPCInfo = $VPCBasicInfo
    )

    $AWSNetList = New-Object System.Collections.ArrayList

    foreach ( $VPC in $VPCBasicInfo ) { 
        
        if ( $($VPC.Agency) -like $Agency -and $($VPC.Environment -like $Environment) ) {

            $FilteredNetworks = Get-EC2Subnet -Filter @( @{name='tag:Name'; values="`*$NetName`*"}; @{name='vpc-id'; values="$($VPC.VPCId)"} ) -ProfileName $($VPC.AccountProfile) 
            
            foreach ( $Network in $FilteredNetworks ) {
                    $NetInfo = New-Object -TypeName PSObject
                    $NetInfo | Add-Member -MemberType NoteProperty -Name Name -Value $($Network.Tags | Where-Object { $_.key -eq "Name"} | select -Expand Value)
                    $NetInfo | Add-Member -MemberType NoteProperty -Name Subnet -Value $Network.CidrBlock
                    $NetInfo | Add-Member -MemberType NoteProperty -Name Agency -Value $VPC.Agency
                    $NetInfo | Add-Member -MemberType NoteProperty -Name Environment -Value $VPC.Environment 
                    $NetInfo | Add-Member -MemberType NoteProperty -Name SubnetId -Value $Network.SubnetId
                    [void]$AWSNetList.Add($NetInfo)
            }
        }
    }

    return $AWSNetList  
}

function Get-SSCAWSInstances { 
    <#
    .SYNOPSIS 
    Get a list of all isntances within the our AWS Accounts - Filter availble 

    .DESCRIPTION 
    using the VPC details object search through all the VPC's and collect basic EC2 instance information 

    .INPUTS 
    None. You cannont pipe objects 

    .PARAMETER Name
    A Filter for the instance Name you are looking for - defaults to * 

    .PARAMETER Agency
    A Filter for the Agency instances  you are looking for - defaults to * 

    .PARAMETER Environment
    A Filter for the Agency instances you are looking for - defaults to * 

    .PARAMETER VPCInfo
    A System.Collections.ArrayList generated from Get-SSCAWSVPCADFS - Defaults to a variable called VPCBasicInfo

    .OUTPUTS
    A list of PSobjects with information about the Instance 

    #>
    [CmdletBinding()]
    Param (
        [string]$Name="*",
        [string]$Agency="*",
        [string]$Environment="*",
        $VPCInfo = $VPCBasicInfo
    )  
    
    $InstanceDetails = New-Object System.Collections.ArrayList
    
    foreach ($VPC in $VPCInfo | Where-Object { $_.Agency -ne "NotFound" -and $_.Agency -like "$($Agency)" -and $_.Environment -like "$($Environment)"   })  {
        $Instances = Get-EC2Instance -Filter @( @{name='tag:Name'; values="`*$Name`*"}; @{name='vpc-id'; values="$($VPC.VPCId)"}; ) -ProfileName $($VPC.AccountProfile)
        foreach ( $Instance in $($Instances.Instances) ) {
            # Some Instances don't have a root device mounted.
            $RootDevice = ($Instance.BlockDeviceMappings | Where-Object { $_.DeviceName -eq $Instance.RootDeviceName })
            if ( $RootDevice )
            {
                $BuildTime = $RootDevice.Ebs.AttachTime
            }
            else { 
                $BuildTime = $null
            }

            $InstanceDetail = New-Object psobject -Property @{
                Name             = $($Instance.Tags | Where-Object { $_.key -eq "Name"} | Select-Object -Expand Value)
                PowerPlan        = $($Instance.Tags | Where-Object { $_.key -eq "PowerExempt"} | Select-Object -Expand Value)
                LeaseTime        = $($Instance.Tags | Where-Object { $_.key -eq "LeaseTime"} | Select-Object -Expand Value  )
                Agency           = $($Instance.Tags | Where-Object { $_.key -eq "Agency"} | Select-Object -Expand Value) 
                AccountId        = $($VPC.AccountId)  
                AvailabilityZone = $($Instance.Placement.AvailabilityZone)
                Id               = $($Instance.InstanceId)
                Platform         = $($Instance.Platform)
                PrimaryIP        = $($Instance.PrivateIpAddress)
                Interfaces       = $($Instance.NetworkInterfaces)
                Type             = $($Instance.InstanceType) 
                LastBootTime     = $([datetime]$Instance.LaunchTime)
                CurrentStatus    = $($Instance.State.Name)
                StatusReason     = $($Instance.StateReason.Message)
                BuildTime        = $BuildTime
                DriveMappings    = $($Instance.BlockDeviceMappings)
                Environment      = $($VPC.Environment)
                VPCAgency        = $($VPC.Agency)
                VPCId            = $($VPC.VPCId)
            }
            [void]$InstanceDetails.add($InstanceDetail)
        }
    }

    return $InstanceDetails
}

function Get-SSCAWSAPPSrv { 
        <#
    .SYNOPSIS 
    From a list of existing instances determine if the server is an App Server and if it is add the PUblic and Private NIC to the server 

    .DESCRIPTION 
    From a list of existing instances determine if the server is an App Server and if it is add the PUblic and Private NIC to the server n 

    .INPUTS 
    None. You cannont pipe objects 

    .PARAMETER Instances
    A Collection of Instances that have come from Get-SSCAWSInstances 

    .PARAMETER Subnets
    A Collection of Subnets from  Get-SSCAWSSubnets

    .PARAMETER VPCInfo
    A System.Collections.ArrayList generated from Get-SSCAWSVPCADFS - Defaults to a variable called VPCBasicInfo

    .OUTPUTS
    A list of PSobjects with information about the Instance 

    #>
    [CmdletBinding()]
    Param (
        $VPCInfo = $VPCBasicInfo,
        $Instances = $Instances,
        $Subnets = $Subnets
    )  

    # Find the application Networks 
    $PublicAppSubnets = $Subnets | Where-Object { $_.Name -like "*Public*" -and $_.Name -like "*App*" }
    $PrivateAppSubnets = $Subnets | Where-Object { $_.Name -like "*Private*" -and $_.Name -like "*App*" }

    #Tag Servers that are App Servers 
    $Instances | Where-Object { ($PublicAppSubnets.SubnetId -contains ($_.Interfaces[0]).SubnetId -or $PrivateAppSubnets.SubnetId -contains ($_.Interfaces[0]).SubnetId) -and ($_.Interfaces).Count -ge 2 } | ForEach-Object {  $_ | Add-Member -MemberType NoteProperty -Name AppSrv -Value $true }
    
    $Instances | Where-Object { $_.AppSrv -eq $null } | ForEach-Object { $_ | Add-Member -MemberType NoteProperty -Name AppSrv -Value $false }


    # Using the Network Filters find which interface is the public interface and which is the Private interface 
    Foreach ( $Instance in $Instances | Where-Object { $_.AppSrv -eq $true } ) { 
        foreach ( $Interface in $Instance.Interfaces ) {
            if ( $PublicAppSubnets.SubnetId -contains $Interface.SubnetId) {
                $Instance | Add-Member -MemberType NoteProperty -Name PublicInterface -Value $Interface -Force
                $Instance | Add-Member -MemberType NoteProperty -Name PublicIP -Value $Interface.PrivateIpAddress -Force
            }
            if ($PrivateAppSubnets.SubnetId -contains $Interface.SubnetId) {
                $Instance | Add-Member -MemberType NoteProperty -Name PrivateInterface -Value $Interface -Force
                $Instance | Add-Member -MemberType NoteProperty -Name PrivateIP -Value $Interface.PrivateIpAddress -Force
            }
        }
    }

    return $Instances
}

function Get-SSCAWSVolumes { 
    <#
    .SYNOPSIS 
    Get a list of all Elastic Block Storage Volumes within the our AWS Accounts - Filter availble 

    .DESCRIPTION 
    using the VPC details object search through all the VPC's and collect basic EC2 EBS Volume information 

    .INPUTS 
    None. You cannont pipe objects 

    .PARAMETER Name
    A Filter for the instance Name you are looking for - defaults to * 

    .PARAMETER Agency
    A Filter for the Agency instances  you are looking for - defaults to * 

    .PARAMETER Environment
    A Filter for the Agency instances you are looking for - defaults to * 

    .PARAMETER InstanceId
    Using the InstanceId Provided find all volumes attached to that instance

    .PARAMETER VPCInfo
    A System.Collections.ArrayList generated from Get-SSCAWSVPCADFS - Defaults to a variable called VPCBasicInfo

    .OUTPUTS
    A list of PSobjects with information about the Volume 

    #>
    [CmdletBinding()]
    Param (
        [string]$Name="*",
        [string]$Agency="*",
        [string]$Environment="*",
        [string]$InstanceId="*",
        $VPCInfo = $VPCBasicInfo
    )  
    $VolumeDetails = New-Object System.Collections.ArrayList
    
    foreach ($VPC in ($VPCInfo | Where-Object { $_.Agency -ne "NotFound" -and $_.Agency -like "$($Agency)" -and $_.Environment -like "$($Environment)" } | Sort-Object -Unique -Property AccountId) )  {
        $Volumes = Get-EC2Volume -ProfileName $($VPC.AccountProfile) -Filter @( @{name='tag:Name'; values="`*$Name`*"}; @{name='attachment.instance-id'; values="`*$InstanceId`*"};)
        foreach ( $Volume in $Volumes ) {
            $EBSVolume = New-Object psobject -Property @{
                Name            = $($Volume.Tags | Where-Object { $_.key -eq "Name"} | select -Expand Value)
                Agency          = $($Volume.Tags | Where-Object { $_.key -eq "Agency"} | select -Expand Value) 
                Environment     = $($VPC.Environment)
                Size            = $Volume.Size
                Status          = $Volume.State
                Type            = $Volume.VolumeType
                Id              = $Volume.VolumeId
                Encrypted       = $Volume.Encrypted
                InstanceOwnerId = $Volume.Attachments.InstanceId
                Created         = $Volume.CreateTime
            }
            [void]$VolumeDetails.Add($EBSVolume)
        }
    }

    return $VolumeDetails
}

