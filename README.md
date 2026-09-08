# GoCast

Монорепозиторий видеохостинга/стриминга: SPA-фронтенд (`web-frontend`) + микросервисы
(identity, stream, transcoder, thumbnail) поверх kind-кластера.

## Быстрый старт (с нуля)

```bash
# 1. Создать кластер kind и настроить контекст на него (вручную, не автоматизировано)
# 2. Убедиться, что `kubectl` смотрит в kind

# 3. Подготовить конфиг (один файл — все не-секретные настройки)
cp .env.example .env            # затем отредактировать .env под себя

# 4. Развернуть инфраструктуру + приложения
make all                        # = render + infra + apps
```

`make all` автоматически:
- `render` — генерирует K8s ConfigMap из `.env` в `deploy/generated/configmaps/`
- `infra` — применяет ConfigMap, ставит namespace/cert-manager/ingress/postgres/redis/minio/KEDA
- `apps` — деплоит identity/stream/transcoder/web-frontend

## Конфигурация (.env)

**Единый источник всех не-секретных настроек — корневой `.env`.**

После изменения `.env`:
```bash
make render                     # перегенерировать ConfigMap
kubectl apply -f deploy/generated/configmaps/.
```

Секреты (пароли, JWT-ключи, CA, MinIO-ключи) остаются в K8s Secret-манифестах в
`services/*/deploy/k8s/` — они вынесены из `.env` осознанно.

### Переменные .env

| Переменная | Назначение | Дефолт |
|---|---|---|
| `DOMAIN` | Основной домен фронтенда | `example.com` |
| `API_DOMAIN` | Домен API/ingress (stream, identity) | `api.example.com` |
| `STORAGE_DOMAIN` | Домен MinIO API | `storage.example.com` |
| `CONSOLE_DOMAIN` | Домен MinIO Console | `console.storage.example.com` |
| `DB_HOST` / `DB_PORT` / `DB_NAME` | PostgreSQL | `postgresql`/`5432`/`database1` |
| `MINIO_ENDPOINT` / `MINIO_BUCKET` / `MINIO_REGION` | MinIO | `minio:9000`/`go-app-bucket`/`us-east-1` |
| `REDIS_ADDR` | Redis (Casbin policy storage) | `casbin-redis-master:6379` |
| `VITE_*` | URL-ы фронта на этапе сборки Docker | `https://api.example.com` и т.д. |

## Сборка веб-фронта

URL-ы фронта подставляются при сборке Docker-образа (build-time, Vite):

```bash
make build-web                  # соберёт xomrkob/web-frontend:latest с URL из .env
```

Для локального dev (Vite): `cd services/web-frontend && pnpm dev` — использует локальный
`.env` в `services/web-frontend/` (gitignored).

## Бэкап / восстановление

PVC живут внутри контейнера kind (`local-path`), поэтому `kind delete` их уничтожает.
Стратегия — **restore**: бэкап перед пересозданием, восстановление после.

```bash
make backup                     # pg_dump + mc mirror -> deploy/backups/<ts>/
# ... пересоздать кластер, make all ...
make restore                    # восстановит последний (первый) бэкап
# или: ./scripts/restore.sh deploy/backups/<ts>/
```

Зависимости: `kubectl`, `helm`, `mc` (MinIO Client).

## Полезные целевые команды

```bash
make status         # pods + ingress
make infra          # инфраструктура (cert-manager, ingress, DB, redis, minio, KEDA)
make apps           # приложения (identity, stream, transcoder, web-frontend)
make uninstall      # удалить namespace go-app
```