from pathlib import Path


def test_no_double_scripts_path():
    forbidden = "scripts/" + "scripts/"
    for path in Path(".").rglob("*"):
        if path.is_file():
            try:
                data = path.read_bytes()
            except PermissionError:
                continue
            if b"\0" in data:
                continue
            text = data.decode(errors="ignore")
            assert forbidden not in text
