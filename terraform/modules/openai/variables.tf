variable "account_name" {
  description = "AOAI account name (also used as custom subdomain)"
  type        = string
}

variable "location" {
  description = "Azure region (australiaeast for reliable GPT-4o per ADR 0004)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "deployment_name" {
  description = "Model deployment name (referenced from n8n HTTP Request URL)"
  type        = string
  default     = "gpt-4o"
}

variable "model_name" {
  description = "Model name"
  type        = string
  default     = "gpt-4o"
}

variable "model_version" {
  description = "Model version (check Azure portal for current; latest stable in AUE)"
  type        = string
  default     = "2024-11-20"
}

variable "sku_name" {
  description = "Deployment SKU — GlobalStandard gives best capacity in AUE"
  type        = string
  default     = "GlobalStandard"
}

variable "deployment_capacity" {
  description = "Deployment capacity in K tokens/minute (10 = 10K TPM, fine for lab)"
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
