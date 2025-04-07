terraform {
  required_version = ">= 0.13"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.11.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group" {
  default = "azuregoat_app"
}

variable "location" {
  type    = string
  default = "eastus" # Change to another region (e.g., "westus") if free tier allows
}

# Generate random ID for unique resource names
resource "random_id" "randomId" {
  keepers = {
    resource_group_name = var.resource_group
  }
  byte_length = 3
}

# Cosmos DB Account
resource "azurerm_cosmosdb_account" "db" {
  name                = "ine-cosmos-db-data-${random_id.randomId.dec}"
  location            = var.location
  resource_group_name = var.resource_group
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level       = "Session" # Simplified for free tier, avoids high staleness
    max_interval_in_seconds = 5
    max_staleness_prefix    = 10
  }

  capabilities {
    name = "EnableServerless" # Free tier default
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

# Storage Account
resource "azurerm_storage_account" "storage_account" {
  name                     = "appazgoat${random_id.randomId.dec}storage"
  resource_group_name      = var.resource_group
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  allow_nested_items_to_be_public = true

  blob_properties {
    cors_rule {
      allowed_headers    = ["*"]
      allowed_methods    = ["GET", "HEAD", "POST", "PUT"]
      allowed_origins    = ["*"]
      exposed_headers    = ["*"]
      max_age_in_seconds = 3600
    }
  }
}

# Storage Container (Single container to simplify, adjust as needed)
resource "azurerm_storage_container" "storage_container" {
  name                  = "appazgoat${random_id.randomId.dec}-storage-container"
  storage_account_name  = azurerm_storage_account.storage_account.name
  container_access_type = "blob"
}

# Local variables for SAS token
locals {
  now       = timestamp()
  sasExpiry = timeadd(local.now, "240h")
  date_now  = formatdate("YYYY-MM-DD", local.now)
  date_br   = formatdate("YYYY-MM-DD", local.sasExpiry)
}

data "azurerm_storage_account_blob_container_sas" "storage_account_blob_container_sas" {
  connection_string = azurerm_storage_account.storage_account.primary_connection_string
  container_name    = azurerm_storage_container.storage_container.name
  start             = local.date_now
  expiry            = local.date_br
  permissions {
    read   = true
    add    = true
    create = true
    write  = true
    delete = false
    list   = false
  }
}

# Populate Cosmos DB Data (Updated to use latest azure-cosmos)
resource "null_resource" "file_populate_data" {
  provisioner "local-exec" {
    command     = <<EOF
sed -i 's/AZURE_FUNCTION_URL/${azurerm_storage_account.storage_account.name}.blob.core.windows.net/${azurerm_storage_container.storage_container.name}/g' modules/module-1/resources/cosmosdb/blog-posts.json
python3 -m venv azure-goat-environment
source azure-goat-environment/bin/activate
pip3 install --upgrade azure-cosmos==4.6.0  # Updated to latest stable version as of 2025
python3 modules/module-1/resources/cosmosdb/create-table.py
EOF
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [azurerm_cosmosdb_account.db, azurerm_storage_account.storage_account, azurerm_storage_container.storage_container]
}

# App Service Plan (Single plan for both function apps)
resource "azurerm_app_service_plan" "app_service_plan" {
  name                = "appazgoat${random_id.randomId.dec}-app-service-plan"
  resource_group_name = var.resource_group
  location            = var.location
  kind                = "FunctionApp"
  reserved            = true
  sku {
    tier = "Dynamic"
    size = "Y1" # Free tier compatible
  }
}

# Function App (Backend)
resource "azurerm_function_app" "function_app" {
  name                       = "appazgoat${random_id.randomId.dec}-function"
  resource_group_name        = var.resource_group
  location                   = var.location
  app_service_plan_id        = azurerm_app_service_plan.app_service_plan.id
  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE"    = "https://${azurerm_storage_account.storage_account.name}.blob.core.windows.net/${azurerm_storage_container.storage_container.name}/${azurerm_storage_blob.storage_blob.name}${data.azurerm_storage_account_blob_container_sas.storage_account_blob_container_sas.sas}"
    "FUNCTIONS_WORKER_RUNTIME"    = "python"
    "JWT_SECRET"                  = "T2BYL6#]zc>Byuzu"
    "AZ_DB_ENDPOINT"              = azurerm_cosmosdb_account.db.endpoint
    "AZ_DB_PRIMARYKEY"            = azurerm_cosmosdb_account.db.primary_key
    "CON_STR"                     = azurerm_storage_account.storage_account.primary_connection_string
    "CONTAINER_NAME"              = azurerm_storage_container.storage_container.name
  }
  os_type = "linux"
  site_config {
    linux_fx_version          = "python|3.9"
    use_32_bit_worker_process = false
    cors {
      allowed_origins = ["*"]
    }
  }
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = "~3"
  depends_on                 = [azurerm_cosmosdb_account.db, azurerm_storage_account.storage_account, null_resource.file_populate_data]
}

# Function App (Frontend)
resource "azurerm_function_app" "function_app_front" {
  name                       = "appazgoat${random_id.randomId.dec}-function-app"
  resource_group_name        = var.resource_group
  location                   = var.location
  app_service_plan_id        = azurerm_app_service_plan.app_service_plan.id
  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE"    = "https://${azurerm_storage_account.storage_account.name}.blob.core.windows.net/${azurerm_storage_container.storage_container.name}/${azurerm_storage_blob.storage_blob_front.name}${data.azurerm_storage_account_blob_container_sas.storage_account_blob_container_sas.sas}"
    "FUNCTIONS_WORKER_RUNTIME"    = "node"
    "AzureWebJobsDisableHomepage" = "true"
  }
  os_type = "linux"
  site_config {
    linux_fx_version          = "node|12"
    use_32_bit_worker_process = false
  }
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = "~3"
  depends_on                 = [azurerm_cosmosdb_account.db, azurerm_storage_account.storage_account]
}

# VM and Networking (Simplified, keep minimal for free tier)
resource "azurerm_network_security_group" "net_sg" {
  name                = "SecGroupNet${random_id.randomId.dec}"
  location            = var.location
  resource_group_name = var.resource_group
  security_rule {
    name                       = "SSH"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "vNet" {
  name                = "vNet${random_id.randomId.dec}"
  address_space       = ["10.1.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group
}

resource "azurerm_subnet" "vNet_subnet" {
  name                 = "Subnet${random_id.randomId.dec}"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.vNet.name
  address_prefixes     = ["10.1.0.0/24"]
  depends_on           = [azurerm_virtual_network.vNet]
}

resource "azurerm_public_ip" "VM_PublicIP" {
  name                = "developerVMPublicIP${random_id.randomId.dec}"
  resource_group_name = var.resource_group
  location            = var.location
  allocation_method   = "Dynamic"
  idle_timeout_in_minutes = 4
  domain_name_label   = lower("developervm-${random_id.randomId.dec}")
  sku                 = "Basic"
}

resource "azurerm_network_interface" "net_int" {
  name                = "developerVMNetInt"
  location            = var.location
  resource_group_name = var.resource_group
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vNet_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.VM_PublicIP.id
  }
  depends_on = [azurerm_network_security_group.net_sg, azurerm_public_ip.VM_PublicIP, azurerm_subnet.vNet_subnet]
}

resource "azurerm_network_interface_security_group_association" "example" {
  network_interface_id      = azurerm_network_interface.net_int.id
  network_security_group_id = azurerm_network_security_group.net_sg.id
}

resource "azurerm_virtual_machine" "dev-vm" {
  name                  = "developerVM${random_id.randomId.dec}"
  location              = var.location
  resource_group_name   = var.resource_group
  network_interface_ids = [azurerm_network_interface.net_int.id]
  vm_size               = "Standard_B1s"
  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true
  identity {
    type = "SystemAssigned"
  }
  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "developerVMDisk"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "developerVM"
    admin_username = "azureuser"
    admin_password = "St0r95p@$sw0rd@1265463541"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  depends_on = [azurerm_network_interface.net_int]
}

# Automation Account (Single instance for free tier)
resource "azurerm_automation_account" "dev_automation_account_test" {
  name                = "dev-automation-account-appazgoat${random_id.randomId.dec}"
  location            = var.location
  resource_group_name = var.resource_group
  sku_name            = "Basic"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.user_id.id]
  }
  tags = {
    environment = "development"
  }
}

resource "azurerm_user_assigned_identity" "user_id" {
  resource_group_name = var.resource_group
  location            = var.location
  name                = "user-assigned-id${random_id.randomId.dec}"
}

# Output
output "Target_URL" {
  value = "https://${azurerm_function_app.function_app_front.name}.azurewebsites.net"
}
