import json
import os
from typing import Tuple

from runtime.civ.provenance.artifact_signing import ArtifactSigner, SignatureVerifier


def make_keypair_hex() -> Tuple[str, str]:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    priv = Ed25519PrivateKey.generate()
    priv_b = priv.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub_b = priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return priv_b.hex(), pub_b.hex()


def test_sign_and_verify_roundtrip(tmp_path):
    # Generate keys
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    private = Ed25519PrivateKey.generate()
    priv_bytes = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public = private.public_key()
    pub_bytes = public.public_bytes(encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)

    os.environ["CIV_SIGNING_KEY"] = priv_bytes.hex()
    os.environ["CIV_PUBLIC_KEY"] = pub_bytes.hex()

    # Create sample artifact
    artifact = {"decision_id": "test-1", "foo": "bar"}

    signer = ArtifactSigner()
    # Sign canonical content
    content_str = json.dumps(artifact, sort_keys=True)
    meta = signer.sign_artifact(content_str)

    # attach signature fields
    artifact["signature"] = meta["signature"]
    artifact["signing_key_id"] = signer.key_id
    artifact["algorithm"] = meta.get("algorithm", "ed25519")
    artifact["signed_content_hash"] = meta["signed_content_hash"]

    # Verify using verifier
    verifier = SignatureVerifier()
    content_str2 = json.dumps(
        {
            k: v
            for k, v in artifact.items()
            if k not in ("signature", "signing_key_id", "algorithm", "signed_content_hash")
        },
        sort_keys=True,
    )
    ok, err = verifier.verify_signature(
        content_str2,
        {
            "algorithm": artifact["algorithm"],
            "key_id": artifact["signing_key_id"],
            "signature": artifact["signature"],
            "signed_content_hash": artifact["signed_content_hash"],
        },
    )
    assert ok, err
