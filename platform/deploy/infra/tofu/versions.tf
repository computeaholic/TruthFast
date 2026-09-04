# ==============================================================================
# PHASE T — OpenTofu Version & Provider Configuration
# ==============================================================================
#
# Purpose:
#   Define version constraints for OpenTofu and all providers.
#   This ensures deterministic, reproducible infrastructure.
#
# Authority:
#   Version pinning is declarative only.
#   No runtime behavior is encoded here.
#   Cloud provider credentials are managed externally.
#
# ==============================================================================

terraform {
  # OpenTofu version constraint
  required_version = ">= 1.6.0"

  # Provider versions
  required_providers {
    # Local provider (for infrastructure intent documentation)
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }

    # Null provider (for deterministic resource tagging)
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
  }
}

# ==============================================================================
# Provider Configuration
# ==============================================================================
#
# Providers are configured per-environment via terraform.tfvars
# This allows environment-specific credentials and settings.
#
# ==============================================================================

# Local provider (always available, no credentials required)
provider "local" {
  # No configuration needed
}

# Null provider (deterministic, no side effects)
provider "null" {
  # No configuration needed
}

# ==============================================================================
# Note: Additional providers (AWS, GCP, k3s, etc.) will be added
# as Phase T expands to cloud infrastructure definition.
# ==============================================================================
