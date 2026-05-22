variable "prefix" {
  description = "Naming prefix for all resources"
  type        = string
  default     = "dsolab"
}

variable "location_primary" {
  description = "Primary Azure region (AKS, ACR, KV, Postgres)"
  type        = string
  default     = "southeastasia"
}

variable "location_aoai" {
  description = "Azure OpenAI region (split out for GPT-4o availability)"
  type        = string
  default     = "australiaeast"
}

variable "resource_group_name" {
  description = "Resource group for all lab resources (created by bootstrap script)"
  type        = string
  default     = "rg-dsolab-sea"
}

variable "github_repo" {
  description = "GitHub org/repo for OIDC federated credential subjects"
  type        = string
  default     = "tonzking123/dsolab"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    project     = "dsolab"
    environment = "lab"
    managed_by  = "terraform"
  }
}
