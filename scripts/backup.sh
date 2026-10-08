#!/usr/bin/env bash
# Logical backup of ADA Core (schemas public + public_api, including grants/RLS/functions).
#   DATABASE_URL=postgresql://... [ADA_BACKUP_DIR=./backups] [ADA_BACKUP_GPG_RECIPIENT=key-id] scripts/backup.sh
# Output: <dir>/ada-core-<UTC timestamp>.dump (+ .sha256, and .gpg when a recipient is given).
# Not included: Supabase Auth data (auth.users) and Storage objects - see docs/operations/BACKUP_RESTORE_MIGRATION.md.
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
dir="${ADA_BACKUP_DIR:-./backups}"; mkdir -p "$dir"; chmod 700 "$dir"
out="$dir/ada-core-$(date -u +%Y%m%dT%H%M%SZ).dump"
umask 077
pg_dump --format=custom --no-owner --schema=public --schema=public_api --file="$out" "$DATABASE_URL"
sha256sum "$out" > "$out.sha256"
# Security posture at backup time; a restore must reproduce it exactly (see scripts/security-fingerprint.sql).
psql -X -Atq "$DATABASE_URL" -f "$(dirname "$0")/security-fingerprint.sql" > "$out.fingerprint"
if [ -n "${ADA_BACKUP_GPG_RECIPIENT:-}" ]; then
  gpg --batch --yes --encrypt --recipient "$ADA_BACKUP_GPG_RECIPIENT" --output "$out.gpg" "$out" && shred -u "$out" 2>/dev/null || rm -f "$out"
  out="$out.gpg"
fi
echo "backup written: $out"
