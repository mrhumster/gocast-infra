FROM golang:1.25.14-alpine AS builder
ARG VERSION=dev
ARG BUILD_DATE=unknown

WORKDIR /app
COPY go.mod ./
RUN if [ -f go.sum ]; then cp go.sum .; fi
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
  -ldflags="-w -s -X main.version=$VERSION -X main.buildDate=$BUILD_DATE" \
  -o db-migrate .

FROM alpine:3.18
ARG VERSION=dev
ARG BUILD_DATE=unknown
LABEL version=$VERSION \
  build-date=$BUILD_DATE \
  maintainer="me@xomrkob.ru"
RUN addgroup -g 1000 appgroup && \
  adduser -D -u 1000 -G appgroup appuser
COPY --from=builder --chown=appuser:appgroup /app/db-migrate /usr/local/bin/db-migrate
USER appuser
ENTRYPOINT ["db-migrate"]