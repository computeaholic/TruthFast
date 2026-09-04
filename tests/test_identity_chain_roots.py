from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))
from identity_chain_roots import IdentityRootError, fingerprint, select_authorized_issuance_root


def _run(*args: str, cwd: pathlib.Path) -> None:
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


def _root(tmp: pathlib.Path, name: str) -> str:
    _run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={name}", "-keyout", f"{name}.key", "-out", f"{name}.crt", "-days", "2", cwd=tmp)
    return (tmp / f"{name}.crt").read_text()


def _issuance(tmp: pathlib.Path, root_name: str, name: str = "issuance") -> str:
    _run("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={name}", "-keyout", f"{name}.key", "-out", f"{name}.csr", cwd=tmp)
    _run("openssl", "x509", "-req", "-in", f"{name}.csr", "-CA", f"{root_name}.crt", "-CAkey", f"{root_name}.key", "-CAcreateserial", "-out", f"{name}.crt", "-days", "1", cwd=tmp)
    return (tmp / f"{name}.crt").read_text()


@pytest.fixture()
def chain_material(tmp_path: pathlib.Path) -> dict[str, str]:
    issuance_root = _root(tmp_path, "issuance-root")
    active_root = _root(tmp_path, "active-root")
    rollover_root = _root(tmp_path, "rollover-root")
    unrelated_root = _root(tmp_path, "unrelated-root")
    issuance = _issuance(tmp_path, "issuance-root")
    unauthorized_issuance = _issuance(tmp_path, "unrelated-root", "unauthorized-issuance")
    return locals()


@pytest.mark.parametrize(
    "live_names,canonical_names",
    [
        (["issuance_root"], ["issuance_root"]),
        (["issuance_root", "active_root"], ["active_root", "issuance_root"]),
        (["rollover_root", "issuance_root", "active_root"], ["active_root", "rollover_root", "issuance_root"]),
        (["active_root", "issuance_root", "rollover_root"], ["issuance_root", "rollover_root", "active_root"]),
        (["issuance_root", "issuance_root", "active_root"], ["active_root", "issuance_root", "issuance_root"]),
    ],
)
def test_legitimate_rollover_is_order_independent_and_deduplicated(chain_material, live_names, canonical_names) -> None:
    live = "".join(chain_material[name] for name in live_names)
    canonical = "".join(chain_material[name] for name in canonical_names)
    root, evidence = select_authorized_issuance_root(live, canonical, chain_material["issuance"])
    assert fingerprint(root) == fingerprint(chain_material["issuance_root"])
    assert evidence["issuance_root_fingerprint"] == fingerprint(chain_material["issuance_root"])


@pytest.mark.parametrize(
    "live_names,canonical_names,issuance_name",
    [
        (["active_root", "rollover_root"], ["active_root", "rollover_root"], "issuance"),
        (["unrelated_root"], ["unrelated_root"], "issuance"),
        (["issuance_root"], ["issuance_root"], "unauthorized_issuance"),
    ],
)
def test_missing_unrelated_and_unauthorized_roots_fail_closed(chain_material, live_names, canonical_names, issuance_name) -> None:
    live = "".join(chain_material[name] for name in live_names)
    canonical = "".join(chain_material[name] for name in canonical_names)
    with pytest.raises(IdentityRootError, match="terminates at 0 authorized roots"):
        select_authorized_issuance_root(live, canonical, chain_material[issuance_name])


def test_cryptographically_valid_root_outside_live_authority_is_unauthorized(chain_material) -> None:
    with pytest.raises(IdentityRootError, match="terminates at 0 authorized roots"):
        select_authorized_issuance_root(
            chain_material["issuance_root"],
            chain_material["issuance_root"] + chain_material["unrelated_root"],
            chain_material["unauthorized_issuance"],
        )
