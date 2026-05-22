output "id" {
  description = "AOAI account resource ID"
  value       = azurerm_cognitive_account.openai.id
}

output "name" {
  description = "AOAI account name"
  value       = azurerm_cognitive_account.openai.name
}

output "endpoint" {
  description = "AOAI endpoint URL (https://<account>.openai.azure.com/)"
  value       = azurerm_cognitive_account.openai.endpoint
}

output "deployment_name" {
  description = "Model deployment name"
  value       = azurerm_cognitive_deployment.gpt4o.name
}
