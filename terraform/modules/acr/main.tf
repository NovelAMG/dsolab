resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku           = "Standard"
  admin_enabled = false # NEVER enable admin user — use RBAC

  public_network_access_enabled = true # private endpoint in Phase 3

  tags = var.tags
}
