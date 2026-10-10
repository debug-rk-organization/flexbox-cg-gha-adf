# Original script: https://github.com/procter-gamble/DA-PP-PDA-Backbone-cicd-templates/tree/master/pipelines/core/templates/adf
# DA-PP-PDA-Backbone-cicd-templates
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    $adfResourceGroup,
    [Parameter(Mandatory)]
    $adfName,
    [Parameter(Mandatory)]
    $pipelinePath,
    [Parameter(Mandatory)]
    $uatFlag,
    [Parameter(Mandatory)]
    $trigger_version,
    [Parameter(Mandatory)]
    $envDeployment,
    [Parameter(Mandatory)]
    $EventTrigger
)

Install-Module -Name Az.DataFactory -Scope CurrentUser -Force -ErrorAction Stop
Get-InstalledModule -Name Az.DataFactory
Import-Module Az.DataFactory

# Sign in to Azure via GitHub OIDC.
if ($env:ACTIONS_ID_TOKEN_REQUEST_URL -and $env:AZURE_CLIENT_ID) {
    # Keep the context in-session only; do not persist credentials to disk.
    Disable-AzContextAutosave -Scope Process | Out-Null

    $tokenUri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange"
    $idToken = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }).value

    Connect-AzAccount -ServicePrincipal `
        -ApplicationId $env:AZURE_CLIENT_ID `
        -TenantId $env:AZURE_TENANT_ID `
        -FederatedToken $idToken `
        -Subscription $env:AZURE_SUBSCRIPTION_ID | Out-Null
}

$adfPath = $pipelinePath

Write-Host "==================================================================="
Write-Host "[TASK] Deploy Azure Data Factory artifacts"
Write-Host "[INFO] Data Factory   : $adfName"
Write-Host "[INFO] Resource group : $adfResourceGroup"
Write-Host "[INFO] Environment    : $envDeployment"
Write-Host "[INFO] Source path    : $adfPath"
Write-Host "[INFO] Event trigger  : $EventTrigger | Versioned triggers: $trigger_version"
Write-Host "==================================================================="
Write-Host "[INFO] Source folder contents:"
Get-ChildItem $adfPath

# Forward slashes resolve correctly on both Windows and Linux agents.
$type_d = "/dataset"
$type_l = "/linkedservice"
$type_p = "/pipeline"
$type_t = "/trigger"
$type_tv = "_trigger"

$envDeploymentwithSlash = "/" + $envDeployment


$dataFactory = Get-AzDataFactoryv2 -ResourceGroupName $adfResourceGroup -Name $adfName -ErrorAction Stop

$files_l = @()
$type_l_akv = '"type": "AzureKeyVault"'

Write-Host "[STEP] Deploying linked services..."

if ($adfPath + $type_l | Test-Path) {

    $files_l += Get-ChildItem ($adfPath + $type_l) -Recurse -Include *.json |
        Sort-Object -Property { $_ | Select-String $type_l_akv -Quiet } -Descending

    foreach ($file in $files_l) {

        if($file.Name -Like "local*"){
            Write-Host "[INFO] Deploying linked service from: $($file.FullName)"

            $json = Get-Content $file.FullName -Raw -ErrorAction Stop
            $svc = $json | ConvertFrom-Json
            $svc.name
            Set-AzDataFactoryV2LinkedService -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Name $svc.name -ResourceGroupName $adfResourceGroup    -Force -ErrorAction Stop
        }
    }
}

$files_d = @()

Write-Host "[STEP] Deploying datasets..."

if ($adfPath + $type_d | Test-Path) {

    $files_d += Get-ChildItem ($adfPath + $type_d) -Recurse -Include *.json

    foreach ($file in $files_d) {
    Write-Host "[INFO] Deploying dataset from: $($file.FullName)"

    $json = Get-Content $file.FullName -Raw -ErrorAction Stop
    $svc = $json | ConvertFrom-Json
    $svc.name
    Set-AzDataFactoryV2Dataset -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Force -ErrorAction Stop  -Name $svc.name -ResourceGroupName $adfResourceGroup
    }
}

function createPipeline([String]$file_name) {
    if (!$files_p_d.Contains($file_name)) {
        $file_path = $adfPath + $type_p + "/" + $file_name
        $pipeline = Get-Content $file_path -Raw -ErrorAction Stop | ConvertFrom-Json

        traverseActivities($pipeline.properties.activities)
        [void]$files_p_d.Add($file_name)

        Write-Host "[INFO] Deploying pipeline: $($file_name)"
        Set-AzDataFactoryV2Pipeline -DataFactory $dataFactory.DataFactoryName -File $file_path -Force `
            -ErrorAction Stop -Name $pipeline.name -ResourceGroupName $adfResourceGroup
    }
}

function traverseActivities([PSCustomObject]$activities) {
    foreach ($activity in $activities) {
        if ($activity.typeProperties.activities) {
            traverseActivities($activity.typeProperties.activities)
        }
        if ($activity.type -eq "ExecutePipeline") {
            createPipeline($activity.typeProperties.pipeline.referenceName + ".json")
        }
    }
}

$files_p = @()
$files_p_d = [System.Collections.ArrayList]::new()

Write-Host "[STEP] Deploying pipelines..."
if ($adfPath + $type_p | Test-Path) {

    $files_p += Get-ChildItem ($adfPath + $type_p) -Recurse -Include *.json

    foreach ($file in $files_p) {
        createPipeline($file.name)
    }
}
if ($EventTrigger -eq $false)
{
    $files_t = @()

    Write-Host "[STEP] Deploying triggers..."
    if($trigger_version -eq $false) {
            if ($adfPath + $type_t | Test-Path) {

            $files_t += Get-ChildItem ($adfPath + $type_t) -Recurse -Include *.json

            foreach ($file in $files_t) {
                Write-Host "[INFO] Processing trigger from: $($file.FullName)"

                $json = Get-Content $file.FullName -Raw -ErrorAction Stop
                $svc = $json | ConvertFrom-Json
                $svc.name

                #create only Schedule Triggers
                if ($svc.properties.type -ne 'BlobEventsTrigger'){
                    #check if trigger exists before stops it
                    $triggers = (Get-AzDataFactoryV2Trigger -ResourceGroupName $adfResourceGroup -DataFactoryName $dataFactory.DataFactoryName).name
                    if ($triggers -contains $svc.name){
                        Write-Host "[INFO] Stopping existing trigger: $($svc.name)"
                        Stop-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                    } else{
                        Write-Host "[INFO] Trigger '$($svc.name)' does not exist yet; nothing to stop"
                    }

                    Write-Host "[INFO] Deploying trigger: $($svc.name)"
                    Set-AzDataFactoryV2Trigger -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Force -ErrorAction Stop -Name $svc.name -ResourceGroupName $adfResourceGroup

                    #start trigger on PROD env and check if on dev it is started
                    if ($uatFlag -eq 0 -and $svc.properties.runtimeState -eq 'Started') {
                        Write-Host "[INFO] Starting trigger: $($svc.name)"
                        Start-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                        }
                    }
                else{
                    Write-Host "[WARN] Skipping '$($svc.name)': blob event triggers are not supported"
                }
            }
        }
    }
    elseif($trigger_version -eq $true) {
        if ($adfPath + $envDeploymentwithSlash + $type_tv | Test-Path) {

            $files_t += Get-ChildItem ($adfPath + $envDeploymentwithSlash + $type_tv) -Recurse -Include *.json

            foreach ($file in $files_t) {
                Write-Host "[INFO] Processing trigger from: $($file.FullName)"

                $json = Get-Content $file.FullName -Raw -ErrorAction Stop
                $svc = $json | ConvertFrom-Json
                $svc.name

                #create only Schedule Triggers
                if ($svc.properties.type -ne 'BlobEventsTrigger'){
                    #check if trigger exists before stops it
                    $triggers = (Get-AzDataFactoryV2Trigger -ResourceGroupName $adfResourceGroup -DataFactoryName $dataFactory.DataFactoryName).name
                    if ($triggers -contains $svc.name){
                        Write-Host "[INFO] Stopping existing trigger: $($svc.name)"
                        Stop-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                    } else{
                        Write-Host "[INFO] Trigger '$($svc.name)' does not exist yet; nothing to stop"
                    }

                    Write-Host "[INFO] Deploying trigger: $($svc.name)"
                    Set-AzDataFactoryV2Trigger -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Force -ErrorAction Stop -Name $svc.name -ResourceGroupName $adfResourceGroup
                    if ($svc.properties.runtimeState -eq 'Started') {
                        Write-Host "[INFO] Starting trigger: $($svc.name)"
                        Start-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                        }
                    }
                else{
                    Write-Host "[WARN] Skipping '$($svc.name)': blob event triggers are not supported"
                }
            }
        }
    }
}
else
{
$files_t = @()

Write-Host "[STEP] Deploying triggers..."
if($trigger_version -eq $false) {
        if ($adfPath + $type_t | Test-Path) {

        $files_t += Get-ChildItem ($adfPath + $type_t) -Recurse -Include *.json

        foreach ($file in $files_t) {
            Write-Host "[INFO] Processing trigger from: $($file.FullName)"

            $json = Get-Content $file.FullName -Raw -ErrorAction Stop
            $svc = $json | ConvertFrom-Json
            $svc.name

                #check if trigger exists before stops it
                $triggers = (Get-AzDataFactoryV2Trigger -ResourceGroupName $adfResourceGroup -DataFactoryName $dataFactory.DataFactoryName).name
                if ($triggers -contains $svc.name){
                    Write-Host "[INFO] Stopping existing trigger: $($svc.name)"
                    Stop-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                } else{
                    Write-Host "[INFO] Trigger '$($svc.name)' does not exist yet; nothing to stop"
                }

                Write-Host "[INFO] Deploying trigger: $($svc.name)"
                Set-AzDataFactoryV2Trigger -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Force -ErrorAction Stop -Name $svc.name -ResourceGroupName $adfResourceGroup

                #start trigger on PROD env and check if on dev it is started
                if ($uatFlag -eq 0 -and $svc.properties.runtimeState -eq 'Started') {
                    Write-Host "[INFO] Starting trigger: $($svc.name)"
                    Start-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                    }

        }
    }
}
    elseif($trigger_version -eq $true) {
        if ($adfPath + $envDeploymentwithSlash + $type_tv | Test-Path) {

            $files_t += Get-ChildItem ($adfPath + $envDeploymentwithSlash + $type_tv) -Recurse -Include *.json

            foreach ($file in $files_t) {
                Write-Host "[INFO] Processing trigger from: $($file.FullName)"

                $json = Get-Content $file.FullName -Raw -ErrorAction Stop
                $svc = $json | ConvertFrom-Json
                $svc.name

                #check if trigger exists before stops it
                    $triggers = (Get-AzDataFactoryV2Trigger -ResourceGroupName $adfResourceGroup -DataFactoryName $dataFactory.DataFactoryName).name
                    if ($triggers -contains $svc.name){
                        Write-Host "[INFO] Stopping existing trigger: $($svc.name)"
                        Stop-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                    } else{
                        Write-Host "[INFO] Trigger '$($svc.name)' does not exist yet; nothing to stop"
                    }
                    Write-Host "[INFO] Deploying trigger: $($svc.name)"
                    Set-AzDataFactoryV2Trigger -DataFactory $dataFactory.DataFactoryName -File $file.FullName -Force -ErrorAction Stop -Name $svc.name -ResourceGroupName $adfResourceGroup
                    if ($svc.properties.runtimeState -eq 'Started') {
                        Write-Host "[INFO] Starting trigger: $($svc.name)"
                        Start-AzDataFactoryV2Trigger -DataFactoryName $dataFactory.DataFactoryName -ResourceGroupName $adfResourceGroup -Name $svc.name -Force -ErrorAction Stop
                        }
            }
        }
    }
}