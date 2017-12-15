# This script is used to autmoate the creation of VPC Peering Connections and their Route table entiries. 
# Peering Connections are defined using a query from Find-RequiredPeers - This search is wild card based and matches on a set of Variables, Environement or Agency and then find the peer links that matches these 
#
# MF2201 - 26/04/2016

## Environement Setup
Import-Module AWSPowerShell
Import-Module SSCAWSADFSPowerShell 

# A manual list of Credential Profiles
$CredObjects = Get-Content -Path '~/AWSProfiles.json' | ConvertFrom-Json

# Setup the Manual Auth Profiles 
ForEach ( $Cred in $CredObjects) { 
    Set-SSCAWSAuthManual -Agency $($Cred.Agency) -Environment $($Cred.Environment) -SecretKey $($Cred.SecretKey) -AccessKey $($Cred.AccessKey)
}

# Setup the Proxy, Attempt SAML Auth and Set default region
Set-SSCAWSEnv -ManualAuthOnly

# Get VPC info
$VPCBasicInfo = Get-SSCAWSVPC

write-host "Welcome to the Peer-O-Matic - AWS VPC Peering "

# For all the accounts in the AWS Account list get all of the VPC peer links in place
function Get-PeerLinks {
    param ( 
        $VPCInfo = $VPCBasicInfo
    )

    # Get all of the Peer links for each account 
    $AllPeerlinks = New-Object System.Collections.ArrayList
    foreach ($VPC in $VPCInfo | Where-Object { $_.VPCId -ne "NotFound"} ) {
        $AccountVPCPeers = Get-EC2VpcPeeringConnections -filter @( @{ name='status-code'; value="active" }) -ProfileName $($VPC.AccountProfile)
        if ($AccountVPCPeers) {
        [void]$AllPeerlinks.AddRange(@($AccountVPCPeers))
        }
    }

    # Since the Peer links are at the account level and the same peer exists between 2 VPC's there will be a lot of duplicates - Lets get rid of them 
    $AllPeerlinks = $AllPeerlinks | Sort-Object VpcPeeringConnectionId -Unique 

    # Strip out the details and put them in a pretty list
    $LinkDetailsList = New-Object System.Collections.ArrayList
    foreach ( $Peerlink in $AllPeerlinks ) { 
        $LinkDetails = New-Object psobject 
        $LinkDetails | Add-Member -MemberType NoteProperty -Name PeerId -Value $($Peerlink.VpcPeeringConnectionId)
        $LinkDetails | Add-Member -MemberType NoteProperty -Name SourceNet -Value $($Peerlink.AccepterVpcInfo.CidrBlock) 
        $LinkDetails | Add-Member -MemberType NoteProperty -Name SourceVPC -Value $($Peerlink.AccepterVpcInfo.VpcId) 
        $LinkDetails | Add-Member -MemberType NoteProperty -Name DestNet -Value $($Peerlink.RequesterVpcInfo.CidrBlock) 
        $LinkDetails | Add-Member -MemberType NoteProperty -Name DestVPC -Value $($Peerlink.RequesterVpcInfo.VpcId) 
        [void]$LinkDetailsList.Add($LinkDetails) 
    }
    
    # Clear out the big duplicate list to reduce memory usage - its really big
    Remove-Variable AllPeerlinks 
    
    return $LinkDetailsList
}

# Create and authorise a VPC peer link between two VPC's - including accounts
function Add-VPCPeer { 
    param(  
            [string]$SourceEnv,
            [string]$DestEnv,
            [string]$SourceAgency,
            [string]$DestAgency,
            $VPCInfo = $VPCBasicInfo
        )
    # Find the Auth and VPC info 
    $SourceVPCInfo = $VPCInfo | Where-Object { $_.Agency -eq $SourceAgency -and $_.Environment -eq $SourceEnv }
    $DestVPCInfo =   $VPCInfo | Where-Object { $_.Agency -eq $DestAgency -and $_.Environment -eq $DestEnv }
    
    Write-host -ForegroundColor Green "- Adding Peer Connection - Source: $($SourceVPCInfo.Agency)_$($SourceVPCInfo.Environment) - $($SourceVPCInfo.VPCId) - Destination: $($DestVPCInfo.Agency)_$($DestVPCInfo.Environment) - $($DestVPCInfo.VPCId)" 
    
    # Offer the VPC link to the destination peer 
    $VPCPeerConection = New-Ec2VpcPeeringConnection -ProfileName $($SourceVPCInfo.AccountProfile) -PeerVpcId $($DestVPCInfo.VPCId) -VpcId $($SourceVPCInfo.VPCId) -PeerOwnerId $($DestVPCInfo.AccountId)
    
    # Accepet the VPC link fom the destination peer 
    $AcceptPeerConnection = Approve-EC2VpcPeeringConnection -ProfileName $($DestVPCInfo.AccountProfile) -VpcPeeringConnectionId $($VPCPeerConection.VpcPeeringConnectionId) 

    #Find the routetables - Ignore the main routetable as this should not be used
    $SourceRouteTables = Get-EC2RouteTable -ProfileName $($SourceVPCInfo.AccountProfile) -Filter @( @{ name='association.main'; value='false' }; @{ name='vpc-id'; value=$($SourceVPCInfo.VPCId) } )
    $DestRouteTables = Get-EC2RouteTable -ProfileName $($DestVPCInfo.AccountProfile)  -Filter @( @{ name='association.main'; value='false' }; @{ name='vpc-id'; value=$($DestVPCInfo.VPCId) } )

    # Add the Route to the Source Routing Tables
    foreach ( $SourceRouteTable in $SourceRouteTables ) {
        
        try
		{
		# Apply the Permissions
		New-EC2Route -ProfileName  $($SourceVPCInfo.AccountProfile) -destinationCidrBlock $( $AcceptPeerConnection.AccepterVpcInfo).CidrBlock -GatewayId $($VPCPeerConection.VpcPeeringConnectionId) -RouteTableId $($SourceRouteTable.RouteTableId)          
		}
		catch  
		{
		if ( $Error[0].Exception -like "*already exists*" ){
			Set-EC2Route -ProfileName $($SourceVPCInfo.AccountProfile) -destinationCidrBlock $( $AcceptPeerConnection.AccepterVpcInfo).CidrBlock -GatewayId $($VPCPeerConection.VpcPeeringConnectionId) -RouteTableId $($SourceRouteTable.RouteTableId)    
		}
        } 
    }
        
    # Add the route to the Destination Routing tables
    foreach ( $DestRouteTable in $DestRouteTables ) {
        try
		{
		# Apply the Permissions
		New-EC2Route -ProfileName $($DestVPCInfo.AccountProfile) -destinationCidrBlock $($AcceptPeerConnection.RequesterVpcInfo).CidrBlock -GatewayId $($VPCPeerConection.VpcPeeringConnectionId) -RouteTableId $($DestRouteTable.RouteTableId)             
		}
		catch  
		{
		if ( $Error[0].Exception -like "*already exists*" ){
			Set-EC2Route -ProfileName $($DestVPCInfo.AccountProfile) -destinationCidrBlock $($AcceptPeerConnection.RequesterVpcInfo).CidrBlock -GatewayId $($VPCPeerConection.VpcPeeringConnectionId) -RouteTableId $($DestRouteTable.RouteTableId)       
		}
        } 
    }

    # Tag it up!
    $NameTag = New-Object Amazon.EC2.Model.Tag
    $NameTag.Key = "Name" 
    $Nametag.Value = "$($SourceVPCInfo.Agency)_$($SourceVPCInfo.Environment) <> $($DestVPCInfo.Agency)_$($DestVPCInfo.Environment)" 
    
    New-EC2Tag -ProfileName $($DestVPCInfo.AccountProfile) -Resource $($VPCPeerConection.VpcPeeringConnectionId) -Tag $NameTag
    New-EC2Tag -ProfileName $($DestVPCInfo.AccountProfile) -Resource $($VPCPeerConection.VpcPeeringConnectionId) -Tag $NameTag
    
}

function Find-RequriedPeers {
    # USAGE:
    # * Use the Source and Dest Parameters to define the VPC that you wish to peer  
    # ** The search is based on Like filters so you can do expressions if required 
    # * The Locks (Agency and Environment) will only allow you to peer between either Agency or Environment
    # ** Eg. Peering IDC to Production for each agency would be SourceEnvironment = IDC DestEnvironment = Production and AgencyLock = true - this means that AgencyA IDC will peer to AgencyA IDC but not to AgencyB's  
    param( 
            [Parameter(Mandatory=$true)][system.collections.arraylist]$PeerLinkList,
            [string]$SourceAgency='*',
            [string]$SourceEnvironment='*',
            [string]$DestAgency='*',
            [string]$DestEnvironment='*', 
            [bool]$AgencyLock=$false,
            [bool]$EnvLock=$false,
            $VPCInfo = $VPCBasicInfo

    )  

    $RequiredPeerLinks = New-Object System.Collections.ArrayList

    $SourceVPCPeerList = $VPCInfo | Where-Object { $_.Agency -like $SourceAgency -and $_.Environment -like $SourceEnvironment } 
    
    Foreach ( $SourceVPCPeer in $SourceVPCPeerList ) {
        $CurrentVPCList = New-Object System.Collections.ArrayList
    
        $PeerList = $PeerLinkList | Where-Object { $_.SourceVPC -contains $($SourceVPCPeer.VPCId) -or $_.DestVPC -contains $($SourceVPCPeer.VPCId) } 

        foreach ( $Peer in $PeerList ) {
            [void]$CurrentVPCList.Add($($Peer.SourceVPC)) 
            [void]$CurrentVPCList.Add($($Peer.DestVPC)) 
        }
    
        [System.Collections.ArrayList]$CurrentVPCList = $CurrentVPCList | Sort-Object -Unique 
    
        # Find all of the  equivlient VPC's 
        $ExpectedVPCList = New-Object System.Collections.ArrayList
        foreach ( $VPC in ($VPCInfo  | Where-Object { $_.Environment -like $DestEnvironment -and $_.Agency -like $DestAgency }) ) {
            [void]$ExpectedVPCList.Add($($VPC.VPCId))
        }

        $MissingVPC = New-Object System.Collections.ArrayList

        if ( $CurrentVPCList -ne $null ) {
            # Compare the list of internal VPC's with the list of Peered VPC's these will be the missing VPC peers 
            $Difference = Compare-Object -ReferenceObject $CurrentVPCList -DifferenceObject $ExpectedVPCList -IncludeEqual | Where-Object { $_.sideIndicator -eq '=>' }

            if ( $Difference -ne $null ) {
                foreach ( $Diff in $Difference ) {
                    [void]$MissingVPC.Add($($Diff.InputObject))   
                }
            }
            else {
                write-host -ForegroundColor Cyan " - No new peering connections required" 
            }
        }
        else { 
            $MissingVPC = $ExpectedVPCList
        }

        foreach ( $VPC in $MissingVPC ) {
            $PeerLink = New-Object psobject
            $PeerLink | Add-Member -MemberType NoteProperty -Name SourceVPCId -Value $($SourceVPCPeer.VPCId) 
            $PeerLink | Add-Member -MemberType NoteProperty -Name SourceEnv -Value $($SourceVPCPeer.Environment)
            $PeerLink | Add-Member -MemberType NoteProperty -Name SourceAgency -Value $($SourceVPCPeer.Agency) 
            $VPCInfo | Where-Object { $_.VPCId -eq $VPC } | ForEach-Object { 
                    $PeerLink | Add-Member -MemberType NoteProperty -Name DestVpcId -Value $_.VPCId
                    $PeerLink | Add-Member -MemberType NoteProperty -Name DestEnv -Value $_.Environment
                    $PeerLink | Add-Member -MemberType NoteProperty -Name DestAgency -Value $_.Agency
                    $PeerLink | Add-Member -MemberType NoteProperty -Name DestAccountId -Value $_.AccountId
            }
            if ( $AgencyLock -eq $true ) {
                if ( $($PeerLink.SourceAgency) -eq $($PeerLink.DestAgency) )  {
                 [void]$RequiredPeerLinks.Add($PeerLink) 
              }
            }
            elseif ( $EnvLock -eq $true ) {
                if ( $($PeerLink.SourceEnv) -eq $($PeerLink.Env) )  {
                   [void]$RequiredPeerLinks.Add($PeerLink)
                }
            }       
            else {
                [void]$RequiredPeerLinks.Add($PeerLink) 
            }
        }
   }

    if ( $AgencyLock -eq $true ) {
        $RequiredPeerLinks = $RequiredPeerLinks | Where-Object { $_.SourceAgency -eq $_.DestAgency } 
    }

    return $RequiredPeerLinks

} 

# Get all of the VPC's and Peer links 
write-host " - Getting current configuration" 

# Get the Current Peer List
$PeerLinkList = Get-PeerLinks -VPCList $VPCList

foreach ( $peerlink in $PeerLinkList) {

    $SourceVPC = $VPCBasicInfo | Where-Object { $_.VPCId -eq $peerlink.SourceVPC}
    $DestVPC = $VPCBasicInfo | Where-Object { $_.VPCid -eq $peerlink.DestVPC}

    #Find the routetables - Ignore the main routetable as this should not be used
    $SourceRouteTables = Get-EC2RouteTable -ProfileName "$($SourceVPC.AccountProfile)" -Filter @( @{ name='association.main'; value='false' }; @{ name='vpc-id'; value=$($SourceVPC.VPCId) } )
    $DestRouteTables = Get-EC2RouteTable -ProfileName "$($DestVPC.AccountProfile)"  -Filter @( @{ name='association.main'; value='false' }; @{ name='vpc-id'; value=$($DestVPC.VPCId) } )


    if ($Peerlink.DestVPC -ne $SourceVPC.VPCId) { 
        # Add the Route to the Source Routing Tables
        foreach ( $SourceRouteTable in $SourceRouteTables ) {
            try
            {
            # Apply the Permissions
                New-EC2Route -ProfileName "$($SourceVPC.AccountProfile)" -destinationCidrBlock $($PeerLink.DestNet) -GatewayId $($Peerlink.PeerId) -RouteTableId $($SourceRouteTable.RouteTableId)        
            }
            catch  
            {
            if ( $Error[0].Exception -like "*already exists*" ){
                Set-EC2Route -ProfileName "$($SourceVPC.AccountProfile)" -destinationCidrBlock $($PeerLink.DestNet) -GatewayId $($Peerlink.PeerId) -RouteTableId $($SourceRouteTable.RouteTableId) 
            }
            } 
        }
    }

    if ($Peerlink.SourceVPC -ne $DestVPC.VPCId ) {      
        # Add the route to the Destination Routing tables
        foreach ( $DestRouteTable in $DestRouteTables ) {
            try
            {
            # Apply the Permissions
                New-EC2Route -ProfileName $($DestVPC.AccountProfile) -destinationCidrBlock $($Peerlink.SourceNet) -GatewayId $($Peerlink.PeerId) -RouteTableId $($DestRouteTable.RouteTableId)             
            }
            catch  
            {
            if ( $Error[0].Exception -like "*already exists*" ){
                Set-EC2Route -ProfileName $($DestVPC.AccountProfile) -destinationCidrBlock $($Peerlink.SourceNet) -GatewayId $($Peerlink.PeerId) -RouteTableId $($DestRouteTable.RouteTableId)           
            }
            } 
        }
    
    }
}

# Refresh Tags:
foreach ( $PeerLink in $PeerLinkList) { 
    # Tag it up!

    $SourceVPCInfo = $VPCBasicInfo | Where-Object { $_.VPCId -eq $PeerLink.SourceVPC }
    $DestVPCInfo = $VPCBasicInfo | Where-Object { $_.VPCId -eq $PeerLink.DestVPC } 

    $PeerLink | Add-Member -MemberType NoteProperty -Name SourceVPCAgency -Value "$($SourceVPCInfo.Agency)" -Force
    $PeerLink | Add-Member -MemberType NoteProperty -Name SourceVPCEnvironment -Value "$($SourceVPCInfo.Environment)" -Force
    $PeerLink | Add-Member -MemberType NoteProperty -Name DestVPCAgency -Value "$($DestVPCInfo.Agency)" -Force
    $PeerLink | Add-Member -MemberType NoteProperty -Name DestVPCEnvironment -Value "$($DestVPCInfo.Environment)" -Force

    $NameTag = New-Object Amazon.EC2.Model.Tag
    $NameTag.Key = "Name" 
    $Nametag.Value = "$($PeerLink.SourceVPCAgency)_$($PeerLink.SourceVPCEnvironment) <> $($PeerLink.DestVPCAgency)_$($PeerLink.DestVPCEnvironment)" 
    
    New-EC2Tag -ProfileName $($SourceVPCInfo.AccountProfile) -Resource $($PeerLink.PeerId) -Tag $NameTag
    New-EC2Tag -ProfileName $($DestVPCInfo.AccountProfile) -Resource $($PeerLink.PeerId) -Tag $NameTag
}

$PeerLinkList | Sort-Object -Property SourceVPCAgency | Format-table -Property SourceNet,DestNet,SourceVPCAgency,SourceVPCEnvironment,DestVPCAgency,DestVPCEnvironment


# ------ STATE CONFIGURTION ----- 
# 
# SSC Management Access
write-host "[*] SSC Management - Production Internal to all Internal" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCMgt" -SourceEnvironment "Production" -DestEnvironment "Production" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCMgt" -SourceEnvironment "Production" -DestEnvironment "Development" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCMgt" -SourceEnvironment "Production" -DestEnvironment "Preproduction" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCMgt" -SourceEnvironment "Production" -DestEnvironment "IDC" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

write-host "[*] SSC Management - IDC to all IDC" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCMgt" -SourceEnvironment "IDC" -DestEnvironment "IDC" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

# Refresh
$PeerLinkList = Get-PeerLinks 

# Common Services  
write-host "[*] SSC Common Services - IDC to IDC" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSC" -SourceEnvironment "IDC" -DestEnvironment "IDC" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

write-host "[*] SSC Common Services - Production to Production" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSC" -SourceEnvironment "Production" -DestEnvironment "Production" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

write-host "[*] SSC Common Services - Preproduction to Preproduction" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSC" -SourceEnvironment "Preproduction" -DestEnvironment "Preproduction" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

write-host "[*] SSC Common Services - Development to Development" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSC" -SourceEnvironment "Development" -DestEnvironment "Development" | ForEach-Object { Add-VPCPeer -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency  -DestEnv $_.DestEnv -DestAgency $_.DestAgency }

# Refresh
$PeerLinkList = Get-PeerLinks 

# SSC Quorum 
write-host "[*] SSC Quorum - Production to Production" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCQuorum" -SourceEnvironment "Production" -DestEnvironment "Production" | ForEach-Object { Add-VPCPeer -SourceVpcId $_.SourceVPCId -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency -DestVpcId $_.DestVpcId -DestEnv $_.DestEnv -DestAgency $_.DestAgency -DestAccountId $_.DestAccountId}

write-host "[*] SSC Quorum - Preproduction to Preproduction" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceAgency "SSCQuorum" -SourceEnvironment "Preproduction" -DestEnvironment "Preproduction" | ForEach-Object { Add-VPCPeer -SourceVpcId $_.SourceVPCId -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency -DestVpcId $_.DestVpcId -DestEnv $_.DestEnv -DestAgency $_.DestAgency -DestAccountId $_.DestAccountId}

# Refresh
$PeerLinkList = Get-PeerLinks 

# IDC to EDC Production
write-host "[*] IDC to EDC - Agency Based" 
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceEnvironment "IDC" -DestEnvironment "Production" -AgencyLock $true | ForEach-Object { Add-VPCPeer -SourceVpcId $_.SourceVPCId -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency -DestVpcId $_.DestVpcId -DestEnv $_.DestEnv -DestAgency $_.DestAgency -DestAccountId $_.DestAccountId}

#ESG LAB to Development
Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceEnvironment "Lab" -SourceAgency "ESG" -DestEnvironment "Development" -DestAgency "ESG" | ForEach-Object { Add-VPCPeer -SourceVpcId $_.SourceVPCId -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency -DestVpcId $_.DestVpcId -DestEnv $_.DestEnv -DestAgency $_.DestAgency -DestAccountId $_.DestAccountId}

Find-RequriedPeers -PeerLinkList $PeerLinkList -SourceEnvironment "Development" -SourceAgency "Legacy" -DestEnvironment "PreProduction" -DestAgency "Legacy" | ForEach-Object { Add-VPCPeer -SourceVpcId $_.SourceVPCId -SourceEnv $_.SourceEnv -SourceAgency $_.SourceAgency -DestVpcId $_.DestVpcId -DestEnv $_.DestEnv -DestAgency $_.DestAgency -DestAccountId $_.DestAccountId}
