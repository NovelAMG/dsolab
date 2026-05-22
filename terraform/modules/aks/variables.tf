variable "cluster_name" {
  description = "AKS cluster name"
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

variable "system_node_count" {
  description = "Number of nodes in the system pool"
  type        = number
  default     = 2
}

variable "system_node_vm_size" {
  description = "VM size for system node pool (Burstable B2s ≈ $30/mo each in SEA)"
  type        = string
  default     = "Standard_B2s"
}

variable "acr_id" {
  description = "ACR resource ID (for AcrPull role assignment)"
  type        = string
}

variable "log_analytics_id" {
  description = "Log Analytics workspace ID (for Container Insights + diagnostics)"
  type        = string
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
