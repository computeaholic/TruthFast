# ==============================================================================
# PHASE T — Cluster Module
# ==============================================================================
#
# Purpose:
#   Define Kubernetes cluster infrastructure primitives.
#   Declarative-only, no operational configuration.
#
# Scope:
#   - Cluster existence (EKS, k3s, k8s version)
#   - Node pool definitions (machine types, count, taints/tolerations)
#   - Control plane configuration (HA, etcd)
#   - Storage class existence (block, object)
#
# Out of Scope:
#   - Workload scheduling (that's Kubernetes scheduler)
#   - Application configuration (that's Kustomize/Argo CD)
#   - Runtime scaling policies (that's no autonomous behavior in ThreadForge)
#   - Istio/CNI configuration (that's runtime, installed via Kustomize)
#
# ==============================================================================

locals {
  cluster_intent = {
    dev = {
      name                = "threadforge-dev"
      version             = "1.28"
      node_count_control  = 1
      node_count_worker   = 2
      machine_type        = "t3.medium"
      storage_gib         = 100
      backup_retention    = 7  # days
    }

    staging = {
      name                = "threadforge-staging"
      version             = "1.28"
      node_count_control  = 1
      node_count_worker   = 3
      machine_type        = "t3.large"
      storage_gib         = 200
      backup_retention    = 30
    }

    prod = {
      name                = "threadforge-prod"
      version             = "1.28"
      node_count_control  = 3
      node_count_worker   = 5
      machine_type        = "m5.xlarge"
      storage_gib         = 500
      backup_retention    = 90
    }
  }
}

# Cluster intent documentation (non-operational)
resource "local_file" "cluster_intent" {
  filename = "${path.module}/intent.yaml"
  content = jsonencode({
    phase              = "T"
    component          = "cluster"
    authority          = "declarative_only"
    version            = "1.0"
    cluster_layout     = local.cluster_intent[var.environment]
    created_at         = timestamp()
  })
}

# ==============================================================================
# Outputs: Cluster Configuration
# ==============================================================================

output "cluster_intent" {
  description = "Cluster configuration intent (for documentation and validation)"
  value       = local.cluster_intent[var.environment]
}

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = local.cluster_intent[var.environment].name
}

output "cluster_version" {
  description = "Kubernetes cluster version"
  value       = local.cluster_intent[var.environment].version
}

output "node_pools" {
  description = "Node pool configuration"
  value = {
    control_plane = {
      node_count   = local.cluster_intent[var.environment].node_count_control
      machine_type = local.cluster_intent[var.environment].machine_type
      purpose      = "Kubernetes control plane nodes"
    }
    worker = {
      node_count   = local.cluster_intent[var.environment].node_count_worker
      machine_type = local.cluster_intent[var.environment].machine_type
      purpose      = "Kubernetes worker nodes"
    }
  }
}

output "storage_capacity_gib" {
  description = "Total storage capacity in GiB"
  value       = local.cluster_intent[var.environment].storage_gib
}

output "backup_retention_days" {
  description = "Backup retention period in days"
  value       = local.cluster_intent[var.environment].backup_retention
}
