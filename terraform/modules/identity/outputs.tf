output "id" {
  description = "Managed identity resource ID"
  value       = azurerm_user_assigned_identity.n8n_aoai.id
}

output "name" {
  description = "Managed identity name"
  value       = azurerm_user_assigned_identity.n8n_aoai.name
}

output "client_id" {
  description = "Client ID — used in the K8s ServiceAccount annotation `azure.workload.identity/client-id` (Phase 1E)"
  value       = azurerm_user_assigned_identity.n8n_aoai.client_id
}

output "principal_id" {
  description = "Principal (object) ID — used for further role assignments"
  value       = azurerm_user_assigned_identity.n8n_aoai.principal_id
}

output "tenant_id" {
  description = "Tenant ID — used by the K8s SA annotation `azure.workload.identity/tenant-id`"
  value       = azurerm_user_assigned_identity.n8n_aoai.tenant_id
}
