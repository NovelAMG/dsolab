output "subscription_id" {
  description = "Active Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

output "tenant_id" {
  description = "Active Entra tenant ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "resource_group_id" {
  description = "Lab resource group ID"
  value       = data.azurerm_resource_group.lab.id
}

# ───── Phase 1B outputs (used by 1D/1E) ─────

output "aks_cluster_name" {
  description = "AKS cluster name (for az aks get-credentials)"
  value       = module.aks.name
}

output "aks_oidc_issuer_url" {
  description = "AKS OIDC issuer URL (needed for n8n SA federated credential in 1D)"
  value       = module.aks.oidc_issuer_url
}

output "acr_login_server" {
  description = "ACR login server (needed for docker push in 1E)"
  value       = module.acr.login_server
}

output "key_vault_name" {
  description = "Key Vault name (needed for CSI driver config in Phase 3)"
  value       = module.keyvault.name
}

output "key_vault_uri" {
  description = "Key Vault data plane URI"
  value       = module.keyvault.vault_uri
}

output "aoai_endpoint" {
  description = "Azure OpenAI endpoint (n8n calls this)"
  value       = module.openai.endpoint
}

output "aoai_deployment_name" {
  description = "AOAI model deployment name (used in n8n HTTP Request URL)"
  value       = module.openai.deployment_name
}

output "postgres_fqdn" {
  description = "Postgres server FQDN (n8n's DB host)"
  value       = module.postgres.fqdn
}

# ───── Phase 1D outputs ─────

output "n8n_workload_identity_client_id" {
  description = "Client ID of mi-n8n-aoai-dsolab. Used in the K8s SA annotation `azure.workload.identity/client-id` in Phase 1E."
  value       = module.identity.client_id
}

output "n8n_workload_identity_name" {
  description = "Name of the n8n workload MI"
  value       = module.identity.name
}

output "spa_app_id" {
  description = "SPA app reg client ID (for MSAL.js config in Phase 1E). Sourced from GitHub variable SPA_APP_ID."
  value       = var.spa_app_id
}

output "n8n_api_app_id" {
  description = "n8n-api app reg client ID (oauth2-proxy uses as audience)."
  value       = var.n8n_api_app_id
}

output "n8n_api_application_id_uri" {
  description = "n8n-api Application ID URI — oauth2-proxy validates incoming tokens against this audience."
  value       = var.n8n_api_app_uri
}
