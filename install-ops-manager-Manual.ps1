## This script is to launch an Ops Manager Director Instance manually without ARM template
## Following the steps on https://docs.pivotal.io/platform/ops-manager/2-8/azure/deploy-manual.html
## Instead of performing each step introduced in the page manually

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

#region Preparation
#region Environment verification
Write-Host "Verifying environment selection"
if (!$Env) {
  Write-Host "Choose Azure environment"
  Write-Host "1) AzureCloud (default)"
  Write-Host "2) AzureChinaCloud"
  Write-Host "3) AzureGermanCloud"
  Write-Host "4) AzureUSGovernment"
  $EnvOpt = Read-Host "Please choose by entering 1, 2, 3 or 4: "
  $Env = "AzureCloud"
  Switch ($EnvOpt) {
    "2" { $Env = "AzureChinaCloud"; }
    "3" { $Env = "AzureGermanCloud"; }
    "4" { $Env = "AzureUSGovernment"; }
    default { $Env = "AzureCloud"; }
  }
}
Switch ($Env) {
  "AzureChinaCloud" { $STORAGE_ENDPOINT = "blob.core.chinacloudapi.cn"; }
  "AzureGermanCloud" { $STORAGE_ENDPOINT = "blob.core.cloudapi.de"; }
  "AzureUSGovernment" { $STORAGE_ENDPOINT = "blob.core.usgovcloudapi.net"; }
  default { $STORAGE_ENDPOINT = "blob.core.windows.net"; }
}
#endregion Environment verification

#region login verification
Write-Host "Verifying Azure CLI"
# check if user has login
$LoginCheck = (az account list 2>&1 | ?{ $_ -match "error" })
if ($LoginCheck) {
  Write-Host "You need login to continue..."
  Write-Host "Login to $Env..."
  az login --environment $Env
}
#region login verification

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

Write-Host "== Creating resource group"
$ret = az group create --name $RESOURCE_GROUP --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.properties.provisioningState -ne "Succeeded") {
    Write-Error "Resource group creation failed"
    return
}
#endregion Preparation

#region Network
Write-Host ""
Write-Host "Step 1: Create Network Resources"
Write-Host ""

#region PCF NSG
Write-Host "== Creating Network Security Group for PCF"
$ret = az network nsg create --name pcf-nsg --resource-group $RESOURCE_GROUP --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.NewNSG.provisioningState -ne "Succeeded") {
    Write-Error "NSG creation failed"
    return
}

Write-Host "Rule: SSH"
$ret = az network nsg rule create --name ssh --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 100 --destination-port-range '22'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 22 creation failed"
    return
}

Write-Host "Rule: HTTP"
$ret = az network nsg rule create --name http --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 200 --destination-port-range '80'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 80 creation failed"
    return
}

Write-Host "Rule: HTTPS"
$ret = az network nsg rule create --name https --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 300 --destination-port-range '443'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 443 creation failed"
    return
}

Write-Host "Rule: Diego-SSH"
$ret = az network nsg rule create --name diego-ssh --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 400 --destination-port-range '2222'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG 2222 rule creation failed"
    return
}
#endregion PCF NSG

#region OpsMan NSG
Write-Host "== Creating Network Security Group for OpsMan"
$ret = az network nsg create --name opsmgr-nsg --resource-group $RESOURCE_GROUP --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.NewNSG.provisioningState -ne "Succeeded") {
    Write-Error "NSG for OpsMan creation failed"
    return
}

Write-Host "Rule: SSH"
$ret = az network nsg rule create --name ssh --nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 100 --destination-port-range '22'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 22 creation failed"
    return
}

Write-Host "Rule: HTTP"
$ret = az network nsg rule create --name http --nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 200 --destination-port-range '80'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 80 creation failed"
    return
}

Write-Host "Rule: HTTPS"
$ret = az network nsg rule create --name https --nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 300 --destination-port-range '443'
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "NSG rule 443 creation failed"
    return
}
#endregion OpsMan NSG

#region VNet
Write-Host "== Creating VNet"
$ret = az network vnet create --name pcf-virtual-network --resource-group $RESOURCE_GROUP --location $LOCATION --address-prefixes 10.0.0.0/16
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.newVNet.provisioningState -ne "Succeeded") {
    Write-Error "VNet creation failed"
    return
}

Write-Host "Subnet: Infrastructure"
$ret = az network vnet subnet create --name pcf-infrastructure-subnet --vnet-name pcf-virtual-network --resource-group $RESOURCE_GROUP --address-prefix 10.0.4.0/26 --network-security-group pcf-nsg
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Subnet infrastructure creation failed"
    return
}

Write-Host "Subnet: PAS"
$ret = az network vnet subnet create --name pcf-pas-subnet --vnet-name pcf-virtual-network --resource-group $RESOURCE_GROUP --address-prefix 10.0.12.0/22 --network-security-group pcf-nsg
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Subnet PAS creation failed"
    return
}

Write-Host "Subnet: Services"
$ret = az network vnet subnet create --name pcf-services-subnet --vnet-name pcf-virtual-network --resource-group $RESOURCE_GROUP --address-prefix 10.0.8.0/22 --network-security-group pcf-nsg
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Subnet Services creation failed"
    return
}
#endregion VNet
#endregion Network

#region Storage Account
Write-Host ""
Write-Host "Step 2: Create BOSH Storage Account"
Write-Host ""

Write-Host "== Creating storage account for BOSH"
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

Write-Host "== Creating containers for Ops Manager and BOSH"

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
#endregion

#region Load Balancer
Write-Host ""
Write-Host "Step 3: Create Load Balancer"
Write-Host ""

#region Public LB
Write-Host "== Creating Load Balancer"
$ret = az network lb create --name pcf-lb --resource-group $RESOURCE_GROUP --location $LOCATION --backend-pool-name pcf-lb-be-pool --frontend-ip-name pcf-lb-fe-ip --public-ip-address pcf-lb-ip --public-ip-address-allocation Static --sku Standard
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.loadBalancer.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer creation failed"
    return
}

Write-Host "Adding Probe"
$ret = az network lb probe create --lb-name pcf-lb --name http8080 --resource-group $RESOURCE_GROUP --protocol Http --port 8080 --path health
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Probe creation failed"
    return
}

Write-Host "Rule: HTTP"
$ret = az network lb rule create --lb-name pcf-lb --name http --resource-group $RESOURCE_GROUP --protocol Tcp --frontend-port 80 --backend-port 80 --frontend-ip-name pcf-lb-fe-ip --backend-pool-name pcf-lb-be-pool --probe-name http8080
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Rule HTTP creation failed"
    return
}

Write-Host "Rule: HTTPS"
$ret = az network lb rule create --lb-name pcf-lb --name https --resource-group $RESOURCE_GROUP --protocol Tcp --frontend-port 443 --backend-port 443 --frontend-ip-name pcf-lb-fe-ip --backend-pool-name pcf-lb-be-pool --probe-name http8080
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Rule HTTPS creation failed"
    return
}
#endregion Public LB

#region Private LB
Write-Host "== Creating Load Balancer for internal IP"
$ret = az network lb create --name pcf-lb --resource-group $RESOURCE_GROUP --location $LOCATION --backend-pool-name pcf-lb-be-pool --frontend-ip-name pcf-lb-fe-ip --private-ip-address 10.0.0.6 --sku Standard
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.loadBalancer.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer (Internal IP) creation failed"
    return
}

Write-Host "Adding Probe"
$ret = az network lb probe create --lb-name pcf-lb --name http8080 --resource-group $RESOURCE_GROUP --protocol Http --port 8080 --path health
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Probe creation failed"
    return
}

Write-Host "Rule HTTP"
$ret = az network lb rule create --lb-name pcf-lb --name http --resource-group $RESOURCE_GROUP --protocol Tcp --frontend-port 80 --backend-port 80 --frontend-ip-name pcf-lb-fe-ip --backend-pool-name pcf-lb-be-pool --probe-name http8080
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Rule HTTP creation failed"
    return
}

Write-Host "Rule HTTPS"
$ret = az network lb rule create --lb-name pcf-lb --name https --resource-group $RESOURCE_GROUP --protocol Tcp --frontend-port 443 --backend-port 443 --frontend-ip-name pcf-lb-fe-ip --backend-pool-name pcf-lb-be-pool --probe-name http8080
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Rule HTTPS creation failed"
    return
}
#endregion Private LB

#region DiegoSSH LB
Write-Host "== Creating Load Balancer for Diego SSH"
$ret = az network lb create --name pcf-ssh-lb --resource-group $RESOURCE_GROUP --location $LOCATION --backend-pool-name pcf-ssh-lb-be-pool --frontend-ip-name pcf-ssh-lb-fe-ip --public-ip-address pcf-ssh-lb-ip --public-ip-address-allocation Static --sku Standard
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.loadBalancer.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer (Diego SSH) creation failed"
    return
}

Write-Host "Adding Probe"
$ret = az network lb probe create --lb-name pcf-ssh-lb --name tcp2222 --resource-group $RESOURCE_GROUP --protocol Tcp --port 2222
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Probe creation failed"
    return
}

Write-Host "Rule SSH"
$ret = az network lb rule create --lb-name pcf-ssh-lb --name diego-ssh --resource-group $RESOURCE_GROUP --protocol Tcp --frontend-port 2222 --backend-port 2222 --frontend-ip-name pcf-ssh-lb-fe-ip --backend-pool-name pcf-ssh-lb-be-pool --probe-name tcp2222
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "Load Balancer Rule SSH creation failed"
    return
}
#endregion DiegoSSH LB
#endregion Load Balancer

#region OpsManager VM
Write-Host ""
Write-Host "Step 4: Boot Ops Manager"
Write-Host ""

#region Prepare Image
Write-Host "== Start copying Ops Manager image into storage account"
az storage blob copy start --source-uri $OPS_MAN_IMAGE_URL --connection-string $CONNECTION_STRING --destination-container opsman-image --destination-blob opsman-image.vhd 

Write-Host -NoNewline "Waiting copying to complete"
$flag = $false
while (-not $flag) {
    Start-Sleep -Seconds 5
    Write-Host -NoNewline "."
    $ret = az storage blob show --name opsman-image.vhd --container-name opsman-image --account-name $STORAGE_NAME
    $ret = $ret -join "" | Out-String | ConvertFrom-Json
    $flag = ($ret.properties.copy.status -eq "success")
}
Write-Host ""
#endregion Prepare Image

#region Prepare Network
Write-Host "== Create a public IP for OpsMan"
$ret = az network public-ip create --name ops-manager-ip --resource-group $RESOURCE_GROUP --location $LOCATION --allocation-method Static
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.publicIp.provisioningState -ne "Succeeded") {
    Write-Error "OpsMan Public IP creation failed"
    return
}
$OpsManIP = $ret.publicIp.ipAddress

Write-Host "== Creating Network Interface for OpsMan"
$ret = az network nic create --vnet-name pcf-virtual-network --subnet pcf-infrastructure-subnet --network-security-group opsmgr-nsg --private-ip-address 10.0.4.4 --public-ip-address ops-manager-ip --resource-group $RESOURCE_GROUP --name opsman-nic --location $LOCATION
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.NewNIC.provisioningState -ne "Succeeded") {
    Write-Error "OpsMan Network Interface creation failed"
    return
}
#endregion Prepare Network

#region Prepare Managed Disk
Write-Host "== Creating managed disk for OpsMan"
$ret = az image create --resource-group $RESOURCE_GROUP --name opsman-image --source https://$STORAGE_NAME.$STORAGE_ENDPOINT/opsman-image/opsman-image.vhd --location $LOCATION --os-type Linux
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.provisioningState -ne "Succeeded") {
    Write-Error "OpsMan Managed Disk creation failed"
    return
}
#endregion Prepare Managed Disk

#region Create VM
Write-Host "== Creating OpsMan VM"
$ret = az vm create --name opsman --resource-group $RESOURCE_GROUP  --location $LOCATION  --nics opsman-nic  --image opsman-image  --os-disk-size-gb 128  --os-disk-name opsman-osdisk  --admin-username ubuntu  --size Standard_DS2_v2  --storage-sku Standard_LRS  --ssh-key-value $ADMIN_PUBLIC_KEY
$ret = $ret -join "" | Out-String | ConvertFrom-Json
if ($ret.powerState -ne "VM running") {
    Write-Error "OpsMan Managed VM creation failed"
    return
}
#endregion Create VM
#endregion OpsManager VM

Write-Host ""
Write-Host "Congratulations, all steps of launching Ops Manager Director Instance have been completed"
Write-Host "Please follow instruction of the link below"
Write-Host "https://docs.pivotal.io/pivotalcf/1-12/customizing/azure-om-config.html"
Write-Host "and setup your Ops Manager Director at address"
Write-Host $OpsManIP
