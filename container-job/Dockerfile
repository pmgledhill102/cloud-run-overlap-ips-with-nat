FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o job main.go

FROM alpine:3.19
COPY --from=builder /app/job /job
ENTRYPOINT ["/job"]
