from __future__ import annotations

import base64
import os
from typing import Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import load_pem_private_key


class SigningError(Exception):
    pass


def load_authority_private_key() -> Optional[object]:
    """Load authority private key from environment variable or file path.

    ENV options:
      THREADFORGE_AUTHORITY_PRIVATE_KEY (PEM contents)
      THREADFORGE_AUTHORITY_PRIVATE_KEY_PATH (file path to PEM)

    Returns a private key object usable for signing, or None if not provided.
    """
    pem = os.getenv("THREADFORGE_AUTHORITY_PRIVATE_KEY")
    path = os.getenv("THREADFORGE_AUTHORITY_PRIVATE_KEY_PATH")

    if pem:
        try:
            key = load_pem_private_key(pem.encode("utf-8"), password=None)
            return key
        except Exception as e:
            raise SigningError(f"failed to load authority private key from env: {e}") from e

    if path:
        try:
            with open(path, "rb") as f:
                key = load_pem_private_key(f.read(), password=None)
                return key
        except Exception as e:
            raise SigningError(f"failed to load authority private key from path: {e}") from e

    return None


def sign_authority_material(private_key, seal: str, identity_hash: str) -> str:
    """Sign the concatenation of seal + '|' + identity_hash and return base64 signature."""
    if private_key is None:
        raise SigningError("private key not loaded")

    material = (seal + "|" + identity_hash).encode("utf-8")
    sig = private_key.sign(
        material,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    return base64.b64encode(sig).decode("ascii")
