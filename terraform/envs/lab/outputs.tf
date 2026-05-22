output "subscription_id" {
  description = "Active Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

output "tenant_id" {
  description = "Active Entra tenant ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "resource_group_id" {
  description = "Lab resource group ID (created by bootstrap script)"
  value       = data.azurerm_resource_group.lab.id
}

output "resource_group_location" {
  description = "Primary region (matches location_primary input)"
  value       = data.azurerm_resource_group.lab.location
}
