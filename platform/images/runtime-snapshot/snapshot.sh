#!/bin/sh
set -e

DAY=$(date +%Y-%m-%d)
TS=$(date +%H-%M)

DEST="/snapshots/$DAY"
mkdir -p "$DEST"

cp -r /logs/operator/ledger "$DEST/ledger-$TS"
echo "[snapshot] created $DEST/ledger-$TS"
