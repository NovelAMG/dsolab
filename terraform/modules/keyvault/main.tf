resource "azurerm_key_vault" "this" {
  name                = var.vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id

  sku_name                  = "standard"
  enable_rbac_authorization = true

  soft_delete_retention_days = 7
  purge_protection_enabled   = false # lab: easy teardown

  public_network_access_enabled = true # private endpoint in Phase 3

  tags = var.tags
}

# Grant the current principal (human or MI running TF) full secret management.
# This is broad on purpose so apply can immediately write secrets in the env.
resource "azurerm_role_assignment" "current_principal_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.current_principal_object_id
}
