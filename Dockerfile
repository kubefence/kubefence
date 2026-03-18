FROM golang:1.24-alpine AS builder
WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o 10-nono-nri ./cmd/nono-nri

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /workspace/10-nono-nri /usr/local/bin/10-nono-nri
# The nono binary must be present in the build context.
# Download or copy it to ./nono before running docker build.
# See: make docker-build
COPY nono /usr/local/bin/nono
ENTRYPOINT ["/usr/local/bin/10-nono-nri"]
