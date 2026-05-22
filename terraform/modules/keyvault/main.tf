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

# Grant Key Vault Administrator to all principals listed in admin_principal_object_ids.
# Typically includes both the TF runner (GHA MI) AND the human admin.
resource "azurerm_role_assignment" "kv_admin" {
  for_each = toset(var.admin_principal_object_ids)

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}
