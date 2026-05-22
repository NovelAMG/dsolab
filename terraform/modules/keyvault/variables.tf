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

variable "current_principal_object_id" {
  description = "Object ID of the principal running Terraform (gets Key Vault Administrator)"
  type        = string
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
