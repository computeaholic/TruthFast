import subprocess

import pytest


pytestmark = pytest.mark.integration


def test_kind_node_image_in_registry():
    image = (
        "registry.threadforge.local:30500/kindest-node@sha256:"
        "48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf"
    )
    result = subprocess.run(["docker", "pull", image], capture_output=True)
    assert result.returncode == 0
