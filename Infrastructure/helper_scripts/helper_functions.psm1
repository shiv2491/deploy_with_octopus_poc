Function New-HoldFile {
    param (
        $holdFileName = "hold",
        $holdFileDir = "C:/holdingFiles"
    )

    # Creating directory for holding files
    if (-not (test-path $holdFileDir)){
        Write-Verbose "    Creating directory: $holdFileDir"
        try {
            New-Item -Type Directory $holdFileDir | out-null
        }
        catch {
            Write-Verbose "    Failed to create directory. This sometimes happens if two runbooks are running simultaneously on the same worker."
            # creating a little random delay to avoid race conditions
            $random = Get-Random -Maximum 10
            Start-Sleep $random
            if (test-path $holdFileDir){
                Write-Verbose "    $holdFileDir now exists now."
            }
            else {
                Write-Error "Failed to create $holdFileDir"
            }
        }
    }

    # Holding file will be created here
    $holdingFile = "$holdFileDir/$holdFileName.txt"
    
    # Checking the RunbookRunId
    $RunbookRunId = "[RunbookRunId unknown]"
    try {
        $RunbookRunId = $OctopusParameters["Octopus.RunbookRun.Id"]
    }
    catch {
        Write-Warning "Unable to read Octopus.RunbookRun.Id from Octopus variables"
    }
    
    # Creating the holding file
    try {
        $RunbookRunId | out-file $holdingFile | out-null
        return $true
    }
    catch {
        Write-Warning "Failed to create holding file."
        return $false
    }
}

Function Test-HoldFile {
    param (
        $holdFileName = "hold",
        $holdFileDir = "C:/holdingFiles"
    )

    # Holding file should be here
    $holdingFile = "$holdFileDir/$holdFileName.txt"

    # Otherwise, return the content of the holding file 
    try {
        $text = Get-Content -Path $holdingFile -Raw
        return $text
    }
    catch {
        return $false
    }
    Write-Error "Something went wrong with the Test-HoldFile function"
}

Function Remove-HoldFile {
    param (
        $holdFileName = "hold",
        $holdFileDir = "C:/holdingFiles"
    )
    
    # Holding file should be here
    $holdingFile = "$holdFileDir/$holdFileName.txt"

    # Deleting the holding file
    try {
        Remove-Item $holdingFile | out-null
    }
    catch {
        Write-Output "Tried to delete $holdingFile but failed."
    }
}

Function Remove-AllHoldFiles {
    param (
        $holdFileDir = "C:/holdingFiles"
    )

    # Deleting all the holding file
    try {
        Remove-Item "$holdFileDir/*" -Force
    }
    catch {
        Write-Warning "Tried to delete $holdFileDir/*, but failed."
    }
}

Function Install-ModuleWithHoldFile {
    param (
        [Parameter(Mandatory=$true)]$moduleName
    )
    
    # Creates a hold file, to warn any parrallel processes
    $holdFileCreated = New-HoldFile -holdFileName $moduleName

    if ($holdFileCreated){
        # Installs the module
        $installed = $false
        try {
            Install-Module $moduleName -Force | out-null
            $installed = $true
        }
        catch {
            Write-Warning "Failed to install $moduleName. Most likely some other process is doing it."
        }
        # Removes the hold file
        Remove-HoldFile -holdFileName $moduleName | out-null
        return $installed
    }
    else {
        return $false
    }
}

Function Test-ModuleInstalled {
    param (
        [Parameter(Mandatory=$true)]$moduleName
    )

    If (Get-InstalledModule $moduleName -ErrorAction silentlycontinue) {
        return $true
    }
    else {
        return $false
    }
}

# Helper function to read and encoding the VM startup scripts
Function Get-UserData {
    param (
        $fileName,
        $octoUrl,
        $environment,
        $role,
        $sql_ip = "unknown",
        $octopusSqlPassword
    )
    
    # retrieving raw source code
    $userDataPath = "$PSScriptRoot\$filename"
    if (-not (Test-Path $userDataPath)){
        Write-Error "No UserData (VM startup script) found at $userDataPath!"
    }
    $userData = Get-Content -Path $userDataPath -Raw
    
    # replacing placeholder text
    $userData = $userData.replace("__OCTOPUSURL__",$octoUrl)
    $userData = $userData.replace("__ENV__",$environment)
    $userData = $userData.replace("__ROLE__",$role)
    $userData = $userData.replace("__SQLSERVERIP__",$sql_ip)
    $userData = $userData.replace("__OCTOPUS_SQL_PASSWORD__",$octopusSqlPassword)

    # Base 64 encoding the userdata file (required by EC2)
    $encodedDbUserData = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($userData))

    # returning encoded userdata
    return $encodedDbUserData
}

# Helper function to get all the existing servers of a particular role
Function Get-Servers {
    param (
        $role = "",
        $environment = "",
        [switch]$includePending
    )
    $acceptableStates = "running"
    if($includePending){
        $acceptableStates = @("pending", "running")
    }

    $filter = @( @{Name="instance-state-name";Values=$acceptableStates} )

    if ($role -notlike ""){
        $filter += @{Name="tag:Role";Values=$role}
    }
    
    if ($environment -notlike ""){
        $filter += @{Name="tag:Environment";Values=$environment}
    }

    $instances = (Get-EC2Instance -Filter $filter).Instances
    return $instances
}

# Helper function to build any servers that don't already exist
Function Start-Servers {
    param (
        [Parameter(Mandatory=$true)]$role,
        [Parameter(Mandatory=$true)]$ami,
        [Parameter(Mandatory=$true)]$environment,
        [Parameter(Mandatory=$true)]$encodedUserData,
        $instanceType = "t2.micro",
        $required = 1
    )
    $existingServers = Get-Servers -role $role -environment $environment -includePending
    $required = $required - $existingServers.count
    $newInstanceIds = @()
    if ($required -gt 0){
        $NewInstances = New-EC2Instance -ImageId $ami -MinCount $required -MaxCount $required -InstanceType $instanceType -UserData $encodedUserData -KeyName my_sql_octopus_poc -SecurityGroup my_sql_octopus_poc -IamInstanceProfile_Name my_sql_octopus_poc
        
        $newInstanceIds = $newInstanceIds + $newInstances.instances.InstanceId
        # Saw a bug where sometimes the New-Ec2Instance cmdlet silently failed, so adding this while loop to try again
        $attempts = 0
        $numTotalInstances = $newInstanceIds.length
        while ($numTotalInstances -lt $required){
            $attempts++
            if ($attempts -gt 10){
                Write-Warning "Failed to create enough instances after 10 attempts. Created $totalInstances out of $required : $newInstanceIds"
                break
            }
            Start-Sleep 1
            $shortfall = $required - $totalInstances
            $extraInstances = New-EC2Instance -ImageId $ami -MinCount $shortfall -MaxCount $shortfall -InstanceType $instanceType -UserData $encodedUserData -KeyName my_sql_octopus_poc -SecurityGroup my_sql_octopus_poc -IamInstanceProfile_Name my_sql_octopus_poc
            $newInstanceIds = $newInstanceIds + $extraInstances.instances.InstanceId
            $numTotalInstances = $newInstanceIds.length
        }
        # Tagging all the instances, regardless of whether weve created enough
        ForEach ($InstanceID  in $newInstanceIds){
            $tags = @( @{key="Project";value="my_sql_octopus_poc"}, `
                       @{key="StartupStatus";value="booting"}, `
                       @{key="Role";value=$role}, `
                       @{key="Environment";value=$environment}, `
                       @{key="Name";value="$role-$environment"} 
                    )
            try {
                New-EC2Tag -Resources $( $InstanceID ) -Tags $tags
            }
            catch {
                # There's a small chance that if we try to tag too quickly, the tag will fail because it won't yet see the instance ID
                # A short wait should fix it. 
                Start-Sleep 5
                New-EC2Tag -Resources $( $InstanceID ) -Tags $tags
            }      
        }
        if ($numTotalInstances -lt $required){
            Write-Error "FAILED: Only have $numTotalInstances after 10 attempts at running the following command: New-EC2Instance -ImageId $ami -MinCount $required -MaxCount $required -InstanceType $instanceType -UserData *** -KeyName my_sql_octopus_poc -SecurityGroup my_sql_octopus_poc -IamInstanceProfile_Name my_sql_octopus_poc"
        }
    }
    return  $newInstanceIds
}

# Helper function to remove an Octopus Tentacle with a given IP address 
function Remove-OctopusMachine {
    param (
        $octoUrl,
        $ip,
        $apiKey
    )
    $header = @{ "X-Octopus-ApiKey" = $apiKey }

    $allMachines = ((Invoke-WebRequest ($octoUrl + "/api/machines") -Headers $header -UseBasicParsing).content | ConvertFrom-Json).items
    $targetMachine = $allMachines | Where-Object {$_.Uri -like "*$ip*"}
    $id = $targetMachine.Id
    try {
        Invoke-RestMethod -Uri "$octoUrl/api/machines/$id" -Headers $header -Method Delete
    }
    catch {
        return "Failed to delete Octopus Target with id: $id. Perhaps it doesn't exits?"
    }    
}

# Checks whether a tentacle exists with a specific IP address
function Test-Tentacle {
    param (
        [Parameter(Mandatory=$true)][string]$ip,
        [Parameter(Mandatory=$true)][string]$octoUrl,
        [Parameter(Mandatory=$true)]$apiKey        
    )
    $URL = "https://" + $ip + ":10933/"
    $header = @{ "X-Octopus-ApiKey" = $apiKey }

    $allMachines = ((Invoke-WebRequest ("$octoUrl/api/machines") -Headers $header -UseBasicParsing).content | ConvertFrom-Json).items
    if ($allMachines.Uri -contains $URL){
        return $true
    }
    else {
        return $false
    }
}

# Updates calimari on a given machine
function Update-Calamari {
    param (
        [Parameter(Mandatory=$true)][string]$ip,
        [Parameter(Mandatory=$true)][string]$OctopusUrl,
        [Parameter(Mandatory=$true)][string]$APIKey
    )
    
    # Creating an API header from API key
    $header = @{ "X-Octopus-ApiKey" = $APIKey }

    $Uri = "https://" + $ip + ":10933/"

    # Use Octopus API to work out MachineName from MachineId
    $allMachines = ((Invoke-WebRequest ("$OctopusUrl/api/machines") -Headers $header -UseBasicParsing).content | ConvertFrom-Json).items
    $thisMachine = $allMachines | Where-Object {$_.Uri -like $Uri}
    $MachineName = $thisMachine.Name
    $MachineId = $thisMachine.Id
    
    # The body of the API call
    $body = @{ 
        Name = "UpdateCalamari" 
        Description = "Updating calamari on $MachineName" 
        Arguments = @{ 
            Timeout= "00:05:00" 
            MachineIds = @($MachineId) #$MachineId could contain an array of machines too
        } 
    } | ConvertTo-Json
    
    Invoke-RestMethod $OctopusUrl/api/tasks -Method Post -Body $body -Headers $header | out-null
}

Function Test-SecretsManagerRoleExists {
    try {
        Get-IAMRole SecretsManager | out-null
        return $true
    }
    catch {
        return $false
    } 
}

Function Test-RoleAddedToProfile {
    param (
        [Parameter(Mandatory=$true)]$InstanceProfileName,
        [Parameter(Mandatory=$true)]$RoleName
    )    
    
    try {
        $added = (Get-IAMInstanceProfileForRole -RoleName $RoleName) | Where-Object {$_.InstanceProfileName -like $InstanceProfileName}
    }
    catch {
        # The role does not exist 
        return $false
    }
    if ($added){
        # The role exists, and is added to the profile
        return $true
    }
    else {
        # The role exists, but is not added to the profile 
        return $false
    }
}

Function Test-ProfileExists {
    param (
        [Parameter(Mandatory=$true)]$InstanceProfileName
    )
    try {
        Get-IAMInstanceProfile -InstanceProfileName $InstanceProfileName | out-null
        return $true
    }
    catch {
        return $false
    }
}

Function Test-SecurityGroup {
    param (
        $groupName
    )
    try {
        Get-EC2SecurityGroup -GroupName $groupName | out-null
        return $true
    }
    catch {
        return $false
    }
}

Function Test-SecurityGroupPorts {
    param (
        $groupName,
        $requiredPorts = @()
    )
    try {
        $sg = Get-EC2SecurityGroup -GroupName $groupName
        $openPorts = $sg.IpPermissions.FromPort
        foreach ($port in $requiredPorts) {
            if ($port -notin $openPorts){
                # SecurityGroup exists, but is misconfigured
                return $false
            }
        }
        # SecurityGroup exists, and all the required ports are open
        return $true
    }
    catch {
        # SecurityGroup probably does not exist
        return $false
    }
}

function Test-KeyPair {
    param (
        $name
    )

    try {
        Get-EC2KeyPair -KeyName $name | out-null
        return $true
    }
    catch {
        return $false
    }
}

function Get-InstanceStatuses{
    param (
        $instances = @()
    )
    $statuses = @()
    foreach ($instance in $instances){
        $status = (Get-EC2Tag -Filter @{Name="resource-id";Values=$resource},@{Name="key";Values="StartupStatus"}).Value
        $statuses += @{$instance=$status}
    }
    return $statuses
}

function Test-IIS {
    param (
        $ip
    )
    try { 
        $content = Invoke-WebRequest -Uri $ip -TimeoutSec 1 -UseBasicParsing
    }
    catch {
        return $false
    }
    if ($content.toString() -like "*iisstart.png*"){
    return $true
    }
}

function Set-OctopusVariable {
    param(
        $octopusURL = "https://xxx.octopus.app/", # Octopus Server URL
        $octopusAPIKey = "API-xxx",               # API key goes here
        $projectName = "",                        # Replace with your project name
        $spaceName = "Default",                   # Replace with the name of the space you are working in
        $environment = $null,                     # Replace with the name of the environment you want to scope the variables to
        $varName = "",                            # Replace with the name of the variable
        $varValue = ""                            # Replace with the value of the variable
    )

    # The code for this function was mostly copied from: 
    # https://github.com/OctopusDeploy/OctopusDeploy-Api/blob/master/REST/PowerShell/Variables/ModifyOrAddVariableToProject.ps1

    # Defines header for API call
    $header = @{ "X-Octopus-ApiKey" = $octopusAPIKey }

    # Get space
    $space = (Invoke-RestMethod -Method Get -Uri "$octopusURL/api/spaces/all" -Headers $header) | Where-Object {$_.Name -eq $spaceName}

    # Get project
    $project = (Invoke-RestMethod -Method Get -Uri "$octopusURL/api/$($space.Id)/projects/all" -Headers $header) | Where-Object {$_.Name -eq $projectName}

    # Get project variables
    $projectVariables = Invoke-RestMethod -Method Get -Uri "$octopusURL/api/$($space.Id)/variables/$($project.VariableSetId)" -Headers $header

    # Get environment to scope to
    $environmentObj = $projectVariables.ScopeValues.Environments | Where { $_.Name -eq $environment } | Select -First 1

    # Define values for variable
    $variable = @{
        Name = $varName  # Replace with a variable name
        Value = $varValue # Replace with a value
        Type = "String"
        IsSensitive = $false
        Scope = @{ 
            Environment = @(
                $environmentObj.Id
                )
            }
    }

    # Check to see if variable is already present. If so, removing old version(s).
    $variablesWithSameName = $projectVariables.Variables | Where-Object {$_.Name -eq $variable.Name}
    
    if ($environmentObj -eq $null){
        # The variable is not scoped to an environment
        $unscopedVariablesWithSameName = $variablesWithSameName | Where-Object { $_.Scope -like $null}
        $projectVariables.Variables = $projectVariables.Variables | Where-Object { $_.id -notin @($unscopedVariablesWithSameName.id)}
    } 
    
    if (@($variablesWithSameName.Scope.Environment) -contains $variable.Scope.Environment){
        # At least one of the existing variables with the same name is scoped to the same environment, removing all matches
        $variablesWithMatchingNameAndScope = $variablesWithSameName | Where-Object { $_.Scope.Environment -like $variable.Scope.Environment}
        $projectVariables.Variables = $projectVariables.Variables | Where-Object { $_.id -notin @($variablesWithMatchingNameAndScope.id)}
    }
    
    # Adding the new value
    $projectVariables.Variables += $variable
    
    # Update the collection
    Invoke-RestMethod -Method Put -Uri "$octopusURL/api/$($space.Id)/variables/$($project.VariableSetId)" -Headers $header -Body ($projectVariables | ConvertTo-Json -Depth 10) | out-null
}