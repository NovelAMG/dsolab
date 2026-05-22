resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name

  # Workload Identity + OIDC issuer — required for n8n → AOAI tokenless auth
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # We disabled the Azure Policy add-on in Phase 1C via Defender settings; keep it off here.
  azure_policy_enabled = false

  default_node_pool {
    name                         = "system"
    node_count                   = var.system_node_count
    vm_size                      = var.system_node_vm_size
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = false # lab: workload pods run here for now
    os_disk_size_gb              = 30
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
  }

  # Container Insights → Log Analytics from day 1 (Defender layered on in Phase 3)
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_id
    msi_auth_for_monitoring_enabled = true
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # autoscaler-friendly
    ]
  }
}

# Allow AKS kubelet identity to pull from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# AKS diagnostic settings → Log Analytics
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }

  metric {
    category = "AllMetrics"
  }
}
