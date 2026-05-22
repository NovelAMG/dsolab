variable "vault_name" {
  description = "Key Vault name (3-24 chars, alphanumeric + hyphens, globally unique)"
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

variable "tenant_id" {
  description = "Entra tenant ID"
  type        = string
}

variable "admin_principal_object_ids" {
  description = "Object IDs of principals to grant Key Vault Administrator (both TF runner and human admin)"
  type        = list(string)
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
