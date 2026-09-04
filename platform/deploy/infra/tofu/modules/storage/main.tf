# ==============================================================================
# PHASE T — Storage Module
# ==============================================================================
#
# Purpose:
#   Define storage infrastructure primitives.
#   Declarative-only, no operational configuration.
#
# Scope:
#   - Object storage buckets (for evidence, exports, logs)
#   - Block storage classes (PV capacity, performance tier)
#   - Database instances (infrastructure-level only)
#   - Backup infrastructure
#
# Out of Scope:
#   - PersistentVolumeClaims (that's runtime, defined in Kustomize)
#   - StatefulSet storage (that's Kubernetes, not infrastructure)
#   - Data lifecycle policies (that's governance/policy, not existence)
#   - Encryption keys (that's security plane, not infrastructure)
#
# ==============================================================================

locals {
  storage_intent = {
    dev = {
      object_storage = {
        bucket_name     = "threadforge-dev-artifacts"
        retention_days  = 7
        encryption      = "sse-s3"
        versioning      = false
      }
      block_storage = {
        storage_classes = {
          standard = {
            size_gib       = 100
            performance    = "general-purpose"
            replication    = "none"
          }
          fast = {
            size_gib       = 50
            performance    = "ssd"
            replication    = "none"
          }
        }
      }
      database = {
        instance_type = "db.t3.micro"
        storage_gib   = 20
        backup_retention_days = 7
        multi_az      = false
      }
    }

    staging = {
      object_storage = {
        bucket_name     = "threadforge-staging-artifacts"
        retention_days  = 30
        encryption      = "sse-s3"
        versioning      = true
      }
      block_storage = {
        storage_classes = {
          standard = {
            size_gib       = 200
            performance    = "general-purpose"
            replication    = "none"
          }
          fast = {
            size_gib       = 100
            performance    = "ssd"
            replication    = "none"
          }
        }
      }
      database = {
        instance_type = "db.t3.small"
        storage_gib   = 50
        backup_retention_days = 30
        multi_az      = false
      }
    }

    prod = {
      object_storage = {
        bucket_name     = "threadforge-prod-artifacts"
        retention_days  = 365
        encryption      = "sse-kms"
        versioning      = true
      }
      block_storage = {
        storage_classes = {
          standard = {
            size_gib       = 500
            performance    = "general-purpose"
            replication    = "2"
          }
          fast = {
            size_gib       = 250
            performance    = "ssd"
            replication    = "3"
          }
        }
      }
      database = {
        instance_type = "db.m5.large"
        storage_gib   = 200
        backup_retention_days = 90
        multi_az      = true
      }
    }
  }
}

# Storage intent documentation (non-operational)
resource "local_file" "storage_intent" {
  filename = "${path.module}/intent.yaml"
  content = jsonencode({
    phase           = "T"
    component       = "storage"
    authority       = "declarative_only"
    version         = "1.0"
    storage_layout  = local.storage_intent[var.environment]
    created_at      = timestamp()
  })
}

# ==============================================================================
# Outputs: Storage Configuration
# ==============================================================================

output "storage_intent" {
  description = "Storage configuration intent (for documentation and validation)"
  value       = local.storage_intent[var.environment]
}

output "object_storage" {
  description = "Object storage configuration"
  value       = local.storage_intent[var.environment].object_storage
}

output "block_storage_classes" {
  description = "Block storage class definitions"
  value       = local.storage_intent[var.environment].block_storage.storage_classes
}

output "database_config" {
  description = "Database infrastructure configuration"
  value       = local.storage_intent[var.environment].database
}

output "total_block_storage_gib" {
  description = "Total block storage capacity"
  value = sum([
    for sc in local.storage_intent[var.environment].block_storage.storage_classes : sc.size_gib
  ])
}
