#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CLUSTER_NAME="kafka-cluster"
KAFKA_NAMESPACE="kafka"

echo -e "${BLUE}🔍 Validating Kafka setup...${NC}"

# Function to print status
print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if cluster exists
if ! kind get clusters | grep -q "$CLUSTER_NAME"; then
    print_error "Kind cluster '$CLUSTER_NAME' not found. Run ./setup.sh first."
    exit 1
fi
print_status "Kind cluster exists"

# Check if namespace exists
if ! kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print_error "Namespace '$KAFKA_NAMESPACE' not found."
    exit 1
fi
print_status "Kafka namespace exists"

# Check Strimzi operator
if ! kubectl get deployment strimzi-cluster-operator -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print_error "Strimzi operator not found."
    exit 1
fi
print_status "Strimzi operator is running"

# Check Kafka cluster
if ! kubectl get kafka kafka-cluster -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print_error "Kafka cluster not found."
    exit 1
fi

# Check if Kafka cluster is ready
KAFKA_STATUS=$(kubectl get kafka kafka-cluster -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$KAFKA_STATUS" != "True" ]; then
    print_warning "Kafka cluster is not ready yet. Status: $KAFKA_STATUS"
else
    print_status "Kafka cluster is ready"
fi

# Check Kafka pods
KAFKA_PODS=$(kubectl get pods -n "$KAFKA_NAMESPACE" -l strimzi.io/name=kafka-cluster-kafka --no-headers | wc -l)
if [ "$KAFKA_PODS" -ne 3 ]; then
    print_warning "Expected 3 Kafka pods, found $KAFKA_PODS"
else
    print_status "All 3 Kafka brokers are running"
fi

# Check test topic
if ! kubectl get kafkatopic test-topic -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print_error "Test topic not found."
    exit 1
fi
print_status "Test topic exists"

# Check demo producer
if ! kubectl get deployment demo-producer -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print_error "Demo producer not found."
    exit 1
fi
print_status "Demo producer is running"

# Check if demo producer is producing messages
PRODUCER_LOGS=$(kubectl logs deployment/demo-producer -n "$KAFKA_NAMESPACE" --tail=5 2>/dev/null | grep -c "Produced message" || echo "0")
if [ "$PRODUCER_LOGS" -gt 0 ]; then
    print_status "Demo producer is generating messages"
else
    print_warning "Demo producer may not be producing messages yet"
fi

echo ""
echo -e "${GREEN}🎉 Validation complete!${NC}"
echo ""
echo -e "${BLUE}📋 Quick commands:${NC}"
echo "  View producer logs: kubectl logs -f deployment/demo-producer -n $KAFKA_NAMESPACE"
echo "  Port forward Kafka: kubectl port-forward service/kafka-cluster-kafka-bootstrap 9092:9092 -n $KAFKA_NAMESPACE"
echo "  Check all pods: kubectl get pods -n $KAFKA_NAMESPACE"
