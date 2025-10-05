#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="kafka-cluster"
KAFKA_NAMESPACE="kafka"

echo "Cleaning up Kafka Kind cluster..."

# Delete the kind cluster
if kind get clusters | grep -q "$CLUSTER_NAME"; then
    echo -e "${YELLOW}Deleting Kind cluster '$CLUSTER_NAME'...${NC}"
    kind delete cluster --name "$CLUSTER_NAME"
    echo -e "${GREEN}✅ Kind cluster deleted${NC}"
else
    echo -e "${YELLOW}No Kind cluster '$CLUSTER_NAME' found${NC}"
fi

echo -e "${GREEN}🎉 Cleanup complete!${NC}"
