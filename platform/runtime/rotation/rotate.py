# runtime/rotation/rotate.py

import os
import shutil
from datetime import datetime

LEDGER_PATH = "runtime/ledger/operator_ledger.jsonl"
ARCHIVE_DIR = "runtime/ledger/archive/"


def rotate():
    os.makedirs(ARCHIVE_DIR, exist_ok=True)

    if not os.path.exists(LEDGER_PATH):
        print("No ledger found.")
        return

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    archive_path = os.path.join(ARCHIVE_DIR, f"operator_ledger_{timestamp}.jsonl")

    shutil.move(LEDGER_PATH, archive_path)

    # create a new blank ledger
    open(LEDGER_PATH, "w").close()

    print(f"Rotated ledger to {archive_path}")
