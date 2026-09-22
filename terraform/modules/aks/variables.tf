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
  # D4as_v5 = 4 vCPU / 16 GiB AMD general-purpose, ~$0.216/hr in SEA.
  # Switched off B4als_v2 burstable after it hit repeated
  # OverconstrainedAllocationRequest (fabric capacity) failures in
  # southeastasia that left the cluster unschedulable. General-purpose Dasv5
  # allocates reliably and gives sustained (non-throttled) vCPU for the
  # Defender sensor + anti-malware daemonset + Image Integrity stack.
  description = "VM size for system node pool"
  type        = string
  default     = "Standard_D4as_v5"
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
