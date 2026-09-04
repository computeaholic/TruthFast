# ==============================================================================
# PHASE T — OpenTofu State Backend Configuration
# ==============================================================================
#
# Purpose:
#   Define remote state backend for infrastructure existence.
#   State is the source of truth for infrastructure provisioning.
#
# Authority:
#   State backend configuration is declarative only.
#   State locking prevents concurrent apply operations.
#   State is encrypted at rest (via backend provider).
#
# Implementation:
#   Local backend (for development/testing)
#   Can be upgraded to S3/Terraform Cloud for production
#
# ==============================================================================

# Local state backend (suitable for development)
# For production, migrate to:
#   - AWS S3 + DynamoDB (for locking)
#   - Terraform Cloud
#   - HashiCorp Consul
terraform {
  backend "local" {
    path = "infra/tofu/state/terraform.tfstate"
  }
}

# Note: Production backend configuration should:
# 1. Use remote backend (S3, Terraform Cloud, etc.)
# 2. Enable state locking (DynamoDB, Consul, etc.)
# 3. Encrypt state in transit (TLS)
# 4. Encrypt state at rest (KMS, TLS)
# 5. Version state snapshots
#
# This will be configured during production hardening.
