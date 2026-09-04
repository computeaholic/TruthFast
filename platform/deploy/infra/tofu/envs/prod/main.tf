# ==============================================================================
# PHASE T — Production Environment Composition
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"
}

module "network" {
  source = "../../modules/network"
  environment = "prod"
}

module "cluster" {
  source = "../../modules/cluster"
  environment = "prod"
}

module "storage" {
  source = "../../modules/storage"
  environment = "prod"
}

output "environment" {
  description = "Environment name"
  value       = "prod"
}

output "network_config" {
  description = "Network infrastructure"
  value = {
    vpc_cidr              = module.network.vpc_cidr
    region                = module.network.region
    availability_zone     = module.network.availability_zone
    subnet_configuration  = module.network.subnets
  }
}

output "cluster_config" {
  description = "Cluster infrastructure"
  value = {
    cluster_name         = module.cluster.cluster_name
    cluster_version      = module.cluster.cluster_version
    node_pools           = module.cluster.node_pools
    storage_capacity_gib = module.cluster.storage_capacity_gib
    backup_retention_days = module.cluster.backup_retention_days
  }
}

output "storage_config" {
  description = "Storage infrastructure"
  value = {
    object_storage       = module.storage.object_storage
    block_storage_classes = module.storage.block_storage_classes
    database_config      = module.storage.database_config
    total_storage_gib    = module.storage.total_block_storage_gib
  }
}

output "infrastructure_exists" {
  description = "Infrastructure existence declaration"
  value = {
    phase       = "T"
    environment = "prod"
    timestamp   = timestamp()
    components  = ["network", "cluster", "storage"]
    status      = "declared"
  }
}
