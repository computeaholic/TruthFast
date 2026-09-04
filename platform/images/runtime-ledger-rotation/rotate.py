import datetime
import os
import shutil

ledger = os.environ["LEDGER_PATH"]
archive = os.environ["ARCHIVE_DIR"]

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d_%H-%M")
dst = os.path.join(archive, f"ledger_{ts}.jsonl")

os.makedirs(archive, exist_ok=True)

if os.path.exists(ledger):
    shutil.copy2(ledger, dst)
    open(ledger, "w").close()  # truncate

print(f"[rotation] Ledger rotated → {dst}")
