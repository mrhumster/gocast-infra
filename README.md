# GoCast

Монорепозиторий видеохостинга/стриминга: SPA-фронтенд (`services/web-frontend`) + микросервисы
(identity, stream, transcoder, thumbnail) поверх kind-кластера.

## Структура репозитория

```
.
├── Makefile                 # все цели: all / render / infra / apps / status / backup / restore / build-web
├── .env                     # единый не-секретный конфиг (gitignored)
├── .env.example             # пример конфига (закоммичен)
├── scripts/
│   ├── render-env.sh        # .env -> K8s ConfigMap (deploy/generated/configmaps/)
│   ├── backup.sh            # pg_dump + mc mirror -> deploy/backups/<ts>/
│   └── restore.sh           # восстановление postgres + minio из бэкапа
├── deploy/
│   ├── generated/configmaps/   # ConfigMap из make render (gitignored)
│   └── backups/                # бэкапы из make backup (gitignored)
└── services/
    ├── identity-service/    # Go: auth (JWT), users, RBAC (Casbin), gRPC permissions, cert-manager/ingress-nginx/postgres/redis setup
    ├── stream-service/      # Go: upload (multipart), HLS, thumbnails, WebSocket, MinIO init/bucket
    ├── transcoder-service/  # Go+ffmpeg: транскодинг видео, масштабируется KEDA
    ├── thumbnail-service/   # Go: генерация превью
    └── web-frontend/        # React 19 SPA (Vite, Tailwind 4, RTK Query, HLS.js)
```

## Архитектура (кратко)

- **REST/WS** наружу отдаёт **stream-service** (/stream/*, /hls/*, WS /stream/ws/updates) и **identity-service** (/auth/*).
- **gRPC (mTLS)** между сервисами: identity ↔ stream ↔ thumbnail/transcoder. Сертификаты — cert-manager `local-ca`, каждый сервис — свой OU.
- **Auth:** JWT access + refresh (identity), RBAC-роли Admin/Member (Casbin, политики в Redis: `casbin-redis-master`).
- **Видео:** multipart-upload в MinIO → транскодинг (transcoder, масштабируется KEDA по очереди) → HLS-сегменты в MinIO → раздача через stream-service.
- **Фронтенд** собирается с build-time URL из `.env` (`VITE_*`).

## Prerequisites

На машине, где выполняется деплой:

| Инструмент | Зачем |
|---|---|
| `kind` | локальный K8s-кластер |
| `kubectl` | apply/деплой, логи подов |
| `helm` | postgres, redis (bitnami), KEDA |
| `docker` | сборка и push образов в Docker Hub |
| `mc` (MinIO Client) | бэкап/восстановление MinIO bucket |

Для локальной разработки фронта — `pnpm` (см. `services/web-frontend/`).

## Быстрый старт (с нуля)

> `make all` НЕ создаёт кластер и НЕ собирает образы — только деплоит на существующий
> кластер образы, уже лежащие в Docker Hub (`xomrkob/*:latest`, `imagePullPolicy: Always`).

```bash
# 1. Создать кластер kind (вручную). Имя — любое, в примерах "desktop".
kind create cluster --name desktop

# 2. Подготовить конфиг (один файл — все не-секретные настройки)
cp .env.example .env            # затем отредактировать .env под себя (домены, ADMIN_EMAIL)
```

Если образы сервисов уже есть в Docker Hub — сразу деплой:

```bash
# 3. Развернуть инфраструктуру + приложения
make all                        # = render + infra + apps + status
```

Если образов (ещё) нет или менялись URL во фронте — сначала собрать и запушить:

```bash
make build-web                          # web-frontend:latest (URL из .env)
make -C services/identity-service build push    # и так же для stream/transcoder/thumbnail
# затем: make all
```

`make all` автоматически:
- `render` — генерирует K8s ConfigMap из `.env` в `deploy/generated/configmaps/`
- `infra` — namespace `go-app`, cert-manager, ingress-nginx, PostgreSQL (Helm), Redis (Helm), MinIO (+ init: bucket/пользователь), KEDA
- `apps` — деплоит identity/stream/transcoder/web-frontend
- `status` — выводит `kubectl get pods` + `kubectl get ingress`

## Конфигурация (.env)

**Единый источник всех не-секретных настроек — корневой `.env`.**

После изменения `.env`:
```bash
make render                     # перегенерировать ConfigMap
kubectl apply -f deploy/generated/configmaps/.
kubectl rollout restart deployment -n go-app identity-service stream-service   # применить
```

Секреты (пароли postgres, Redis, MinIO, JWT-ключи, CA) остаются в K8s Secret-манифестах и
Helm-параметрах в `services/*/deploy/k8s/` — они вынесены из `.env` осознанно. Если они потеряются
вместе с кластером — их надо восстановить вручную (см. «Учёт секретов» ниже).

### Переменные .env

| Переменная | Назначение | Пример |
|---|---|---|
| `DOMAIN` | Основной домен фронтенда | `example.com` |
| `API_DOMAIN` | Домен API/ingress (stream, identity) | `api.example.com` |
| `STORAGE_DOMAIN` | Домен MinIO API | `storage.example.com` |
| `CONSOLE_DOMAIN` | Домен MinIO Console | `console.storage.example.com` |
| `ADMIN_EMAIL` | Бутстрап-админ (identity присваивает role=admin) | `me@xomrkob.ru` |
| `DB_HOST` / `DB_PORT` / `DB_NAME` | PostgreSQL | `postgresql`/`5432`/`database1` |
| `MINIO_ENDPOINT` / `MINIO_BUCKET` / `MINIO_REGION` | MinIO | `minio:9000`/`go-app-bucket`/`us-east-1` |
| `REDIS_ADDR` | Redis (Casbin policy storage) | `casbin-redis-master:6379` |
| `VITE_*` | URL-ы фронта на этапе сборки Docker (make build-web) | `https://api.example.com` и т.д. |

## Бэкап / восстановление (Disaster Recovery)

PVC живут внутри контейнера kind, поэтому `kind delete` уничтожает данные:
postgres — `hostpath` 8Gi, Redis — без persistence, MinIO — in-container storage.
Стратегия — **restore**: бэкап перед пересозданием, восстановление после.

### Полный сценарий

```bash
# 1. КЛАСТЕР ЖИВ — сделать бэкап данных (postgres.dump + minio/)
make backup                         # -> deploy/backups/<timestamp>/

# 2. Потеряли кластер (или намеренное пересоздание)
kind delete cluster --name desktop

# 3. Развернуть заново
kind create cluster --name desktop
cp .env.example .env                # если .env тоже потерян — заполнить заново
make all

# 4. Восстановить данные из последнего бэкапа
B=$(ls -d deploy/backups/*/ | sort | tail -1)
./scripts/restore.sh "$B"           # pg_restore --clean + mc mirror
# (make restore без аргумента только перечислит доступные бэкапы)
```

> `make` заново инстанцирует Redis с тем же hardcoded паролем (`password`), поэтому
> Casbin-политики identity пересоздаст сам при старте (seed ролей + роли существующих
> пользователей из `ADMIN_EMAIL`). gRPC mTLS-сертификаты cert-manager тоже пересоздаст
> заново — ничего «докатывать» не нужно, кроме данных выше.

### Учёт секретов при полной потере

`make` не восстановит из `.env`:
- postgres-пароль `Master1234` (зашит в `services/identity-service/deploy/k8s/postgres/values.yaml`)
- Redis-пароль `password` (hardcoded в Makefile `deploy-redis`)
- MinIO `minio-credentials` (Secret в кластере) — если потерян, пересоздать вручную и повторно:
  `make -C services/stream-service init-minio`
- JWT-ключи, gRPC CA (Secret-манифесты в `services/*/deploy/k8s/`) — восстанавливаются из git-манифестов при `make all`

Если они были изменены/сгенерированы в рантайме (а не из git-манифестов) — их нужно заготовить до `make`.

## Полезные команды

```bash
make all            # полный деплой: render + infra + apps + status
make render         # только перегенерация ConfigMap из .env
make infra          # инфраструктура (cert-manager, ingress, postgres, redis, minio, KEDA)
make apps           # приложения (identity, stream, transcoder, web-frontend)
make status         # pods + ingress
make backup         # pg_dump + mc mirror -> deploy/backups/<ts>/
make build-web      # собрать и запушить web-frontend:latest (URL из .env)
make uninstall      # удалить namespace go-app
```

Dev-фронт локально: `cd services/web-frontend && pnpm dev` (Vite на :5173).
Сборка сервиса: `make -C services/<service> build push deploy` (образ `xomrkob/<service>:<git-tag>` + latest).

## Известные проблемы

- **kindnet veth-флаки (WSL2/Docker Desktop)** — поды Running, но pod→pod TCP до postgres/redis
  таймаутит (симптом: 504, зависшие login/upload). Лечение: пересоздать kindnet + postgres/redis поды
  (`kubectl delete pod -n kube-system -l k8s-app=kindnet`, затем pg/redis). Рецидивно.
- **Postgres PVC `hostpath`** — живёт только пока жив контейнер kind; без `make backup` перед `kind delete` данные теряются.
- **WebSocket** — токен передаётся в `Sec-WebSocket-Protocol` (subprotocol), сервер обязан эхировать его при handshake.