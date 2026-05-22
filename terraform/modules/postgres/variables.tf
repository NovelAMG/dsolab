variable "server_name" {
  description = "Postgres Flex server name (globally unique)"
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

variable "administrator_login" {
  description = "SQL administrator username"
  type        = string
  default     = "psqladmin"
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
