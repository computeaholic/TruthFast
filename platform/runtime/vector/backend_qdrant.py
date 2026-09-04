# Path: runtime/vector/backend_qdrant.py
class QdrantBackend:
    name = "qdrant"

    def __init__(self):
        from qdrant_client import QdrantClient

        self.client = QdrantClient("http://qdrant.qdrant:6333")

    def insert(self, envelope):
        return self.client.upsert(
            collection_name=envelope.namespace,
            points=[{"id": envelope.id, "vector": envelope.vector, "payload": envelope.payload}],
        )

    def search(self, envelope):
        return self.client.search(
            collection_name=envelope.namespace,
            query_vector=envelope.vector,
            limit=envelope.top_k,
        )
