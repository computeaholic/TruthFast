from pathlib import Path

import pytest
import yaml


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_api_prod_values_use_threadforge_api_image_repo() -> None:
    doc = yaml.safe_load((REPO_ROOT / "platform" / "deploy" / "services" / "api" / "values-prod.yaml").read_text())

    image = doc["image"]
    assert image["repository"] == "registry.threadforge.local:30500/threadforge-api"
    assert image["digest"] == "sha256:eb55cee8e7baedb754731d405b302713225510bad398508c206c187c1c6fa0e9"
