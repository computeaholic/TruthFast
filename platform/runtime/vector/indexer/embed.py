# runtime/vector/indexer/embed.py
"""Embedding interface for vector generation.
Supports local models first, deterministic output.
"""

from typing import Any, Protocol


class EmbeddingModel(Protocol):
    """Protocol for embedding models."""

    @property
    def model_name(self) -> str:
        """Return the model name for metadata."""
        ...

    @property
    def vector_size(self) -> int:
        """Return the output vector size."""
        ...

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        """Embed a batch of texts into vectors."""
        ...


class LocalSentenceTransformer:
    """Local sentence transformer implementation."""

    def __init__(self, model_name: str):
        try:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(model_name)
            self._model_name = model_name
        except ImportError as err:
            raise RuntimeError(
                "sentence-transformers not available. Install with: pip install sentence-transformers",
            ) from err

    @property
    def model_name(self) -> str:
        return self._model_name

    @property
    def vector_size(self) -> int:
        dim = self._model.get_sentence_embedding_dimension()
        if dim is None:
            raise RuntimeError(f"Could not determine vector size for model {self._model_name}")
        return dim

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        """Embed texts using local transformer."""
        embeddings = self._model.encode(texts, convert_to_list=True)
        # Ensure we return the correct type
        if isinstance(embeddings, list) and all(isinstance(e, list) for e in embeddings):
            return embeddings
        raise RuntimeError(f"Unexpected embedding format from model {self._model_name}")


def create_embedding_model(model_name: str) -> EmbeddingModel:
    """Factory function to create embedding model."""
    # Support local models first
    if model_name.startswith("sentence-transformers/"):
        local_name = model_name.replace("sentence-transformers/", "")
        return LocalSentenceTransformer(local_name)

    # Placeholder for other model types
    raise ValueError(f"Unsupported model: {model_name}. Supported: sentence-transformers/*")


def embed_batch(model: EmbeddingModel, records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Embed a batch of records.
    Returns records with 'vector' and 'model_name' added.
    """
    if not records:
        return []

    texts = [record["embed_text"] for record in records]
    vectors = model.embed_texts(texts)

    # Add vector and model metadata to each record
    for record, vector in zip(records, vectors, strict=True):
        record["vector"] = vector
        record["model_name"] = model.model_name

    return records
