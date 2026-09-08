#!/usr/bin/env bash
# ============================================================
# GoCast — бэкап данных перед пересозданием кластера (стратегия restore)
# Сохраняет:
#   - PostgreSQL (pg_dump)   -> deploy/backups/<ts>/postgres.dump
#   - MinIO bucket (mc mirror) -> deploy/backups/<ts>/minio/
# Запуск: ./scripts/backup.sh   (или make backup)
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${ROOT}/deploy/backups/$(date +%Y%m%d-%H%M%S)"
NAMESPACE="${NAMESPACE:-go-app}"

mkdir -p "${BACKUP_DIR}/minio"

echo "==> Бэкап в ${BACKUP_DIR}"

# --- PostgreSQL ---
echo "==> PostgreSQL: pg_dump ..."
PG_POD=$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${PG_POD}" ]]; then
  PG_POD=$(kubectl -n "${NAMESPACE}" get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "${PG_POD}" ]]; then
  echo "ERROR: postgres pod не найден в namespace ${NAMESPACE}" >&2
  exit 1
fi
kubectl -n "${NAMESPACE}" exec "${PG_POD}" -- sh -c 'pg_dump -U ${POSTGRES_USER:-postgres} ${POSTGRES_DB:-postgres}' > "${BACKUP_DIR}/postgres.dump"
echo "  ok: ${BACKUP_DIR}/postgres.dump"

# --- MinIO ---
echo "==> MinIO: mc mirror ..."
if ! command -v mc >/dev/null 2>&1; then
  echo "    mc не найден в PATH — пропускаю MinIO-бэкап." >&2
  echo "    Установи: curl -o mc https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x mc"
  echo "    И запусти: mc alias set local <host> <user> <pass>"
  exit 0
fi
# генерим alias на основе секрета в кластере
ROOT_USER=$(kubectl -n "${NAMESPACE}" get secret minio-credentials -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d 2>/dev/null || echo "admin")
ROOT_PASS=$(kubectl -n "${NAMESPACE}" get secret minio-credentials -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d 2>/dev/null || true)
if [[ -z "${ROOT_PASS}" ]]; then
  echo "    Не удалось получить MINIO_ROOT_PASSWORD из кластера — пропускаю MinIO-бэкап." >&2
  exit 0
fi
BUCKET="${MINIO_BUCKET:-go-app-bucket}"
mc alias set backup-target http://localhost:9000 "${ROOT_USER}" "${ROOT_PASS}" >/dev/null 2>&1 || {
  echo "    Попробуй: mc alias set backup-target http://127.0.0.1:9000 ${ROOT_USER} <pass>" >&2
  exit 0
}
mc mirror --overwrite backup-target/"${BUCKET}" "${BACKUP_DIR}/minio/"
echo "  ok: ${BACKUP_DIR}/minio/"

echo "==> Готово. Бэкап в: ${BACKUP_DIR}"
echo "    Восстановление: ./scripts/restore.sh ${BACKUP_DIR}"