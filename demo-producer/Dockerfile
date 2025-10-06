FROM golang:1.22-alpine AS builder

WORKDIR /app

COPY go.* ./
RUN go mod download

COPY . .
RUN go build -o kafka-producer producer.go

FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/kafka-producer .

ENTRYPOINT ["/app/kafka-producer"]
