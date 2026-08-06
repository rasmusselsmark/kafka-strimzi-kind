#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="kafka-cluster"
KAFKA_NAMESPACE="kafka"
STRIMZI_NAMESPACE="strimzi"

# Function to print messages
print() {
    echo "$1"
}

print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print "🧹 Cleaning up Kafka Kind cluster..."

# Check if we should do a full cleanup or just resources
if [ "$1" = "--resources-only" ]; then
    print "Cleaning up resources only (keeping cluster)..."

    # Set kubectl context
    kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1 || {
        print_error "Kind cluster '$CLUSTER_NAME' not found or not accessible"
        exit 1
    }

    # Delete Prometheus Operator resources
    print "Deleting Prometheus Operator resources..."
    helm uninstall prometheus-operator -n "$KAFKA_NAMESPACE" >/dev/null 2>&1 || print_warning "Prometheus Operator not found"

    # Delete KMinion
    print "Deleting KMinion..."
    helm uninstall kminion -n "$KAFKA_NAMESPACE" >/dev/null 2>&1 || print_warning "KMinion not found"

    # Delete Kafka resources
    print "Deleting Kafka resources..."
    kubectl delete -f manifests/ --ignore-not-found=true -n "$KAFKA_NAMESPACE" >/dev/null 2>&1

    # Delete namespaces (the Strimzi namespace holds the cluster operator)
    print "Deleting namespaces..."
    kubectl delete namespace "$KAFKA_NAMESPACE" "$STRIMZI_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1

    # The cluster-wide bindings added by setup.sh outlive the namespaces
    print "Deleting Strimzi cluster-wide role bindings..."
    kubectl delete clusterrolebinding \
        strimzi-cluster-operator-namespaced \
        strimzi-cluster-operator-watched \
        strimzi-cluster-operator-entity-operator-delegation \
        --ignore-not-found=true >/dev/null 2>&1

    print_status "Resources cleaned up"
else
    # Full cleanup - delete the entire cluster
    if kind get clusters | grep -q "$CLUSTER_NAME"; then
        print_warning "Deleting Kind cluster '$CLUSTER_NAME'..."
        kind delete cluster --name "$CLUSTER_NAME"
        print_status "Kind cluster deleted"
    else
        print_warning "No Kind cluster '$CLUSTER_NAME' found"
    fi
fi

print
echo -e "${GREEN}🎉 Cleanup complete!${NC}"
print
print "Usage:"
print "  ./cleanup.sh                  - Delete entire Kind cluster (default)"
print "  ./cleanup.sh --resources-only - Clean up resources but keep cluster"
