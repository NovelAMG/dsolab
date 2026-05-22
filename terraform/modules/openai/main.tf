resource "azurerm_cognitive_account" "openai" {
  name                = var.account_name
  location            = var.location
  resource_group_name = var.resource_group_name

  kind     = "OpenAI"
  sku_name = "S0"

  # Required for Entra ID authentication (no shared regional endpoint)
  custom_subdomain_name = var.account_name

  # ⭐ Core security control: no API keys, ever.
  local_auth_enabled = false

  public_network_access_enabled = true # private endpoint in Phase 3

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# GPT-4o model deployment
resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = var.deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.sku_name
    capacity = var.deployment_capacity
  }
}
