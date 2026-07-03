#!/bin/bash

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/set-versions.sh"

# Colors for output
BLUE='\033[0;34m'
NC='\033[0m' # No Color

KAFKA_NAMESPACE="kafka"
TOPIC="${1:-test-topic}"

echo -e "${BLUE}📥 Starting Kafka message consumer...${NC}"
echo "This will consume messages from the '$TOPIC' topic"
echo "Press Ctrl+C to stop"
echo ""

kubectl -n "$KAFKA_NAMESPACE" run kafka-consumer --image="quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}" --rm -it --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic "$TOPIC" --from-beginning
