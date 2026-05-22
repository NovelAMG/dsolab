# Generated password for the SQL admin; stored in Key Vault by the env composition.
resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "_%@"
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version    = "16"
  sku_name   = "B_Standard_B1ms" # Burstable B1ms (~$15/mo)
  storage_mb = 32768             # 32 GB
  zone       = "1"

  administrator_login    = var.administrator_login
  administrator_password = random_password.postgres_admin.result

  # Hybrid auth: keeps the SQL admin (used by n8n) AND allows Entra admins (humans).
  # Phase 3 hardening: consider Entra-only after wiring workload identity into n8n's pg driver.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = var.tenant_id
  }

  public_network_access_enabled = true # private endpoint in Phase 3
  backup_retention_days         = 7

  tags = var.tags

  lifecycle {
    ignore_changes = [zone] # AZ can drift after maintenance
  }
}

# Lab firewall: allow all Azure services (the 0.0.0.0 special rule).
# Phase 3 replaces this with a private endpoint in the AKS VNet.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "AllowAllAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
