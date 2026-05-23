variable "name" {
  description = "Managed identity name (e.g. mi-n8n-aoai-dsolab)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (from azurerm_kubernetes_cluster.oidc_issuer_url)"
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace where the consuming pod will run"
  type        = string
  default     = "n8n"
}

variable "k8s_service_account" {
  description = "Kubernetes ServiceAccount name the FIC binds to"
  type        = string
  default     = "n8n"
}

variable "aoai_account_id" {
  description = "Azure OpenAI account resource ID (scope for the role assignment)"
  type        = string
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
