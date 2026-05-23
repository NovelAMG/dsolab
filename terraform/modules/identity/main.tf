resource "azurerm_user_assigned_identity" "n8n_aoai" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Federated identity credential binds this MI to a Kubernetes ServiceAccount
# that doesn't exist yet (Phase 1E creates `n8n:n8n`). The binding only
# activates when the SA + the AKS workload identity webhook are both in place.
resource "azurerm_federated_identity_credential" "k8s_sa" {
  name                = "${var.name}-k8s-sa"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.n8n_aoai.id
  subject             = "system:serviceaccount:${var.k8s_namespace}:${var.k8s_service_account}"
}

# RBAC: n8n's identity can call Azure OpenAI (data plane).
# "Cognitive Services OpenAI User" allows inference (chat completions, embeddings)
# but NOT model deployment management.
resource "azurerm_role_assignment" "aoai_user" {
  scope                = var.aoai_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.n8n_aoai.principal_id
}
