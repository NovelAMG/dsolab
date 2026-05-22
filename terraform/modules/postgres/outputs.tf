output "id" {
  description = "Postgres Flex server resource ID"
  value       = azurerm_postgresql_flexible_server.this.id
}

output "name" {
  description = "Server name"
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Server FQDN (e.g., psql-dsolab-sea-xxxx.postgres.database.azure.com)"
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "administrator_login" {
  description = "SQL admin username"
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "administrator_password" {
  description = "SQL admin password (sensitive — stored in Key Vault by env)"
  value       = random_password.postgres_admin.result
  sensitive   = true
}
