# ==============================================================================
# PHASE T — Network Module
# ==============================================================================
#
# Purpose:
#   Define network infrastructure primitives.
#   Declarative-only, no dynamic logic.
#
# Scope:
#   - Network segmentation intent
#   - Namespace/VLAN/subnet declarations
#   - Routing table structure
#   - Security group rules (coarse-grained)
#
# Out of Scope:
#   - Kubernetes network policy (that's in Kustomize)
#   - Service routing (that's Istio)
#   - Calico/Flannel configuration (that's runtime)
#
# ==============================================================================

locals {
  network_intent = {
    dev = {
      cidr              = "10.0.0.0/16"
      region            = "us-west-2"
      availability_zone = "us-west-2a"
      subnets = {
        control_plane = {
          cidr_offset = 0  # 10.0.0.0/24
          purpose     = "Kubernetes control plane nodes"
        }
        worker = {
          cidr_offset = 1  # 10.0.1.0/24
          purpose     = "Kubernetes worker nodes"
        }
        storage = {
          cidr_offset = 2  # 10.0.2.0/24
          purpose     = "Storage infrastructure (PVs, databases)"
        }
      }
    }

    staging = {
      cidr              = "10.1.0.0/16"
      region            = "us-west-2"
      availability_zone = "us-west-2b"
      subnets = {
        control_plane = {
          cidr_offset = 0  # 10.1.0.0/24
          purpose     = "Kubernetes control plane nodes"
        }
        worker = {
          cidr_offset = 1  # 10.1.1.0/24
          purpose     = "Kubernetes worker nodes"
        }
        storage = {
          cidr_offset = 2  # 10.1.2.0/24
          purpose     = "Storage infrastructure (PVs, databases)"
        }
      }
    }

    prod = {
      cidr              = "10.2.0.0/16"
      region            = "us-west-2"
      availability_zone = "us-west-2c"
      subnets = {
        control_plane = {
          cidr_offset = 0  # 10.2.0.0/24
          purpose     = "Kubernetes control plane nodes"
        }
        worker = {
          cidr_offset = 1  # 10.2.1.0/24
          purpose     = "Kubernetes worker nodes"
        }
        storage = {
          cidr_offset = 2  # 10.2.2.0/24
          purpose     = "Storage infrastructure (PVs, databases)"
        }
      }
    }
  }
}

# Network intent documentation (non-operational)
# This serves as a source of truth for network design decisions
resource "local_file" "network_intent" {
  filename = "${path.module}/intent.yaml"
  content = jsonencode({
    phase           = "T"
    component       = "network"
    authority       = "declarative_only"
    version         = "1.0"
    network_layout  = local.network_intent[var.environment]
    created_at      = timestamp()
  })
}

# ==============================================================================
# Outputs: Network Configuration
# ==============================================================================
# These outputs feed downstream infrastructure definition.

output "network_intent" {
  description = "Network topology intent (for documentation and validation)"
  value       = local.network_intent[var.environment]
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = local.network_intent[var.environment].cidr
}

output "region" {
  description = "Cloud region"
  value       = local.network_intent[var.environment].region
}

output "availability_zone" {
  description = "Primary availability zone"
  value       = local.network_intent[var.environment].availability_zone
}

output "subnets" {
  description = "Subnet configuration"
  value       = local.network_intent[var.environment].subnets
}
