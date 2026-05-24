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
  # B4als_v2 = 4 vCPU / 8 GiB AMD burstable, ~$0.06/hr in SEA.
  # Upgraded from B2s (2 vCPU / 4 GiB) in ADR-0018 to fit Defender sensor +
  # anti-malware daemonset + Image Integrity headroom. AMD burstable is the
  # cheapest tier that gives enough RAM for the 3.7+ phase stack.
  description = "VM size for system node pool"
  type        = string
  default     = "Standard_B4als_v2"
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
