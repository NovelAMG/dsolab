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

# Note: Key Vault Administrator role assignments are intentionally NOT managed
# here. See ADR 0008. They are granted at RG scope by scripts/00-bootstrap-state.sh
# to both the GHA MI and the human admin. Managing them in TF caused a chicken-and-egg
# deadlock when the role assignment was refactored (CREATE conflicts with existing,
# DELETE+CREATE leaves a gap where TF loses KV access mid-apply).
