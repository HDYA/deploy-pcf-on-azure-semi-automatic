## This script is to launch an Ops Manager Director Instance with an ARM Template
## Following the steps on https://docs.pivotal.io/pivotalcf/1-11/customizing/azure-arm-template.html
## Instead of performing mannual steps introduced in the page

############################ CONFIGS ############################

# region Include parameters
$ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
try {
    . ("$ScriptDirectory\install-ops-manager-Parameters.ps1")
}
catch {
    Write-Host "Error while trying to load parameters PowerShell Scripts" 
}
#endregion

############################ SCRIPTS ############################

Write-Host "Verifying Azure CLI"
$Env = "AzureCloud"
$STORAGE_ENDPOINT = "blob.core.windows.net"
# check if user has login
$LoginCheck = (az account list 2>&1 | ?{ $_ -match "error" })
if ($LoginCheck) {
  Write-Host "You need login to continue..."
  Write-Host "Which Azure environment do you want to login?"
  Write-Host "1) AzureCloud (default)"
  Write-Host "2) AzureChinaCloud"
  Write-Host "3) AzureUSGovernment"
  Write-Host "4) AzureGermanCloud"
  $EnvOpt = Read-Host "Please choose by entering 1, 2, 3 or 4: "
  $Env = "AzureCloud"
  $STORAGE_ENDPOINT = "blob.core.windows.net"
  if ("$EnvOpt" -eq 2) {
    $Env = "AzureChinaCloud"
    $STORAGE_ENDPOINT = "blob.core.chinacloudapi.cn"
  }
  if ("$EnvOpt" -eq 3) {
    $Env = "AzureUSGovernment"
    $STORAGE_ENDPOINT = "blob.core.usgovcloudapi.net"
  }
  if ("$EnvOpt" -eq 4) {
    $Env = "AzureGermanCloud"
    $STORAGE_ENDPOINT = "blob.core.cloudapi.de"
  }
  Write-Host "Login to $Env..."
  az login --environment $Env
}

Write-Host ""
Write-Host "Step 1: Create BOSH Storage Account"
Write-Host ""

Write-Host "Selecting Subscription"
$SubscriptionCheck = (az account set --subscription  $SUBSCRIPTION_ID 2>&1 | ?{ $_ -match "exist" })
if ($SubscriptionCheck) {
    Write-Error "Invalid Subscription, not exist in specified region or has more than 1 match"
    return
}

Write-Host "Fetching Tenant ID"
$ret = az account show
$ret = $ret -join "" | Out-String | ConvertFrom-Json
$TENANT_ID = $ret.tenantId
Write-Host "Tenant ID: " $TENANT_ID

Write-Host "Creating resource group"
$ret = az group create --name $RESOURCE_GROUP --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.properties.provisioningState -ne "Succeeded") {
    Write-Error "Resource group creation failed"
    return
}

Write-Host "Creating storage account for BOSH"
$ret = az storage account create --name $STORAGE_NAME --resource-group $RESOURCE_GROUP --sku Standard_LRS --kind Storage --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Storage creation creation failed"
    return
}

Write-Host "Fetching connection string of storage account created"
$ret = az storage account show-connection-string --name $STORAGE_NAME --resource-group $RESOURCE_GROUP
$ret = $ret -join "" | Out-String | ConvertFrom-Json
$CONNECTION_STRING = $ret.connectionString
Write-Host "Connection string: " $CONNECTION_STRING

Write-Host "Creating containers for Ops Manager and BOSH"

Write-Host "Container: opsman-image"
$ret = az storage container create --name opsman-image --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for Ops Manager image"
    return
}

Write-Host "Container: vhds"
$ret = az storage container create --name vhds --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for Ops Manager VMs"
    return
}

Write-Host "Container: opsmanager"
$ret = az storage container create --name opsmanager --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for Ops Manager"
    return
}

Write-Host "Container: bosh"
$ret = az storage container create --name bosh --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for BOSH"
    return
}

Write-Host "Container: stemcell"
$ret = az storage container create --name stemcell --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for stemcell"
    return
}

Write-Host "Table: stemcells"
$ret = az storage table create --name stemcells --connection-string $CONNECTION_STRING
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if (-not $ret.created) {
    Write-Error "Error while creating container for stemcell"
    return
}

Write-Host ""
Write-Host "Step 2: Copy Ops Manager Image"
Write-Host ""

Write-Host "Start copying Ops Manager image into storage account"
az storage blob copy start --source-uri $OPS_MAN_IMAGE_URL --connection-string $CONNECTION_STRING --destination-container opsman-image --destination-blob image.vhd 

Write-Host -NoNewline "Waiting copying to complete"
$flag = $false
while (-not $flag) {
    Start-Sleep -Seconds 5
    Write-Host -NoNewline "."
    $ret = az storage blob show --name image.vhd --container-name opsman-image --account-name $STORAGE_NAME
    $ret = $ret -join "" | Out-String | ConvertFrom-Json
    $flag = ($ret.properties.copy.status -eq "success")
}
Write-Host ""

Write-Host ""
Write-Host "Step 3: Configure the ARM Template"
Write-Host ""

Write-Host "Cloning template from GitHUb"
Remove-Item pcf-azure-arm-templates -Recurse -Force
git clone https://github.com/pivotal-cf/pcf-azure-arm-templates.git
if (cd .\pcf-azure-arm-templates\ 2>&1 | ?{ $_ -match "does not exist" }) {
    Write-Error "Local template not exist, please make sure you have git installed"
    return
}

Write-Host "Customizing ARM template parameters"
$PARAMETERS = Get-Content azure-deploy-parameters.json 
$PARAMETERS = $PARAMETERS -join "" | Out-String | ConvertFrom-Json

Write-Host "Using storage account: " $STORAGE_NAME
$PARAMETERS.parameters.OpsManVHDStorageAccount = ("{value: '$STORAGE_NAME'}" | ConvertFrom-Json)

Write-Host "Using storage container: " "opsman-image"
$PARAMETERS.parameters.BlobStorageContainer = ("{value: 'opsman-image'}" | ConvertFrom-Json)

Write-Host "Using storage endpoint: " $STORAGE_ENDPOINT
$PARAMETERS.parameters.BlobStorageEndpoint = ("{value: ''}" | ConvertFrom-Json)
$PARAMETERS.parameters.BlobStorageEndpoint.value = $STORAGE_ENDPOINT

Write-Host "Using admin public key: " $ADMIN_PUBLIC_KEY
$PARAMETERS.parameters.AdminSSHKey = ("{value: ''}" | ConvertFrom-Json)
$PARAMETERS.parameters.AdminSSHKey.value = $ADMIN_PUBLIC_KEY

Write-Host "Using Environment: " $CF_ENV
$PARAMETERS.parameters.Environment = ("{value: '$CF_ENV'}" | ConvertFrom-Json)

Write-Host "Using location: " $LOCATION
$PARAMETERS.parameters.Location = ("{value: '$LOCATION'}" | ConvertFrom-Json)

Write-Host "Writing ARM template parameters"
$PARAMETERS | ConvertTo-Json | Out-File -FilePath azure-deploy-parameters.json -Encoding ascii 

Write-Host ""
Write-Host "Step 4: Deploy the ARM Template and Deployment Storage Accounts"
Write-Host ""

Write-Host "Deploying ARM template"
$ret = az group deployment create --template-file azure-deploy.json --parameters azure-deploy-parameters.json --resource-group $RESOURCE_GROUP --name cfdeploy

$ret = $ret -join "" | Out-String | ConvertFrom-Json
$OPS_MANAGER_URL = $ret.properties.outputs.'opsMan-FQDN'.value
$STORAGE_ACCOUNT_PREFIX = $ret.properties.outputs.'extra Storage Account Prefix'.value

Write-Host "Creating network security group"
$ret = az network nsg create --name pcf-nsg --resource-group $RESOURCE_GROUP --location $LOCATION

Write-Host "Adding rules to network security group"
if ($ret = az network nsg rule create --name internet-to-lb --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 100 --destination-port-range '*' 2>&1 | ?{ $_ -match "not found" }) {
    Write-Error "Network security group not found, creation may have failed"
    return
}

Write-Host ""
Write-Host "Congratulations, all steps of launching Ops Manager Director Instance have been completed"
Write-Host "Please follow instruction of the link below"
Write-Host "https://docs.pivotal.io/pivotalcf/1-12/customizing/azure-om-config.html"
Write-Host "and setup your Ops Manager Director at address"
Write-Host $OPS_MANAGER_URL
