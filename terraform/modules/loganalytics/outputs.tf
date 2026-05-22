output "id" {
  description = "Log Analytics workspace resource ID"
  value       = azurerm_log_analytics_workspace.this.id
}

output "name" {
  description = "Workspace name"
  value       = azurerm_log_analytics_workspace.this.name
}

output "workspace_id" {
  description = "Customer/workspace ID (GUID) used by agents"
  value       = azurerm_log_analytics_workspace.this.workspace_id
}
