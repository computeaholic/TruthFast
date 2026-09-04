from enum import Enum


class KernelIntent(str, Enum):
    STORAGE_WRITE = "storage.write"
    STORAGE_READ = "storage.read"
    STORAGE_LIST = "storage.list"

    VECTOR_ROUTE = "vector.route"

    OBSERVE_ENVOY_CERTS = "observe.envoy.certs"

    IDENTITY_DEMAND = "identity.demand"
