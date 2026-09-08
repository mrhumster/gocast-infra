#!/usr/bin/env bash
# ============================================================
# GoCast — восстановление данных после пересоздания кластера
# Используется ПОСЛЕ: kind delete/create && make infra apps
#   - PostgreSQL: pg_restore из postgres.dump
#   - MinIO bucket: mc mirror обратно
# Запуск: ./scripts/restore.sh <backup-dir>
#         ./scripts/restore.sh deploy/backups/20260908-120000
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-go-app}"

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  mkdir -p "${ROOT}/deploy/backups" 2>/dev/null || true
  AVAIL=$(ls -d "${ROOT}"/deploy/backups/*/ 2>/dev/null || true)
  if [[ -z "${AVAIL}" ]]; then
    echo "ERROR: укажи папку с бэкапом: ./scripts/restore.sh <dir>" >&2
    exit 1
  fi
  echo "Доступные бэкапы:"
  echo "${AVAIL}"
  exit 1
fi
BACKUP_DIR="$(cd "${BACKUP_DIR}" && pwd)"

echo "==> Восстановление из ${BACKUP_DIR}"

# --- PostgreSQL ---
echo "==> PostgreSQL: pg_restore ..."
PG_POD=$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${PG_POD}" ]]; then
  PG_POD=$(kubectl -n "${NAMESPACE}" get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "${PG_POD}" ]]; then
  echo "ERROR: postgres pod не найден. Убедись что make infra apps выполнен." >&2
  exit 1
fi
DUMP="${BACKUP_DIR}/postgres.dump"
if [[ -f "${DUMP}" ]]; then
  kubectl -n "${NAMESPACE}" cp "${DUMP}" "${PG_POD}:/tmp/restore.dump"
  kubectl -n "${NAMESPACE}" exec "${PG_POD}" -- sh -c 'pg_restore -U ${POSTGRES_USER:-postgres} --clean --if-exists -d ${POSTGRES_DB:-database1} /tmp/restore.dump; rm -f /tmp/restore.dump'
  echo "  ok: postgres restored"
else
  echo "  нет postgres.dump — пропускаю PostgreSQL."
fi

# --- MinIO ---
echo "==> MinIO: mc mirror обратно ..."
if ! command -v mc >/dev/null 2>&1; then
  echo "  mc не найден в PATH — пропускаю MinIO-восстановление." >&2
  exit 0
fi
ROOT_USER=$(kubectl -n "${NAMESPACE}" get secret minio-credentials -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d 2>/dev/null || echo "admin")
ROOT_PASS=$(kubectl -n "${NAMESPACE}" get secret minio-credentials -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d 2>/dev/null || true)
BUCKET="${MINIO_BUCKET:-go-app-bucket}"
mc alias set restore-target http://localhost:9000 "${ROOT_USER}" "${ROOT_PASS}" >/dev/null 2>&1 || {
  echo "  Попробуй: mc alias set restore-target http://127.0.0.1:9000 ${ROOT_USER} <pass>" >&2
  exit 0
}
mc mb --ignore-existing restore-target/"${BUCKET}" >/dev/null 2>&1 || true
mc mirror --overwrite "${BACKUP_DIR}/minio/" restore-target/"${BUCKET}" || true
echo "  ok: minio restored"

echo "==> Восстановление завершено."