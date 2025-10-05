#!/bin/bash

set -e

# Colors for output
BLUE='\033[0;34m'
NC='\033[0m' # No Color

KAFKA_NAMESPACE="kafka"

echo -e "${BLUE}📥 Starting Kafka message consumer...${NC}"
echo "This will consume messages from the test-topic"
echo "Press Ctrl+C to stop"
echo ""

kubectl run kafka-consumer --image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0 --rm -it --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic test-topic --from-beginning
