#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="kafka-cluster"
KAFKA_NAMESPACE="kafka"
STRIMZI_VERSION="latest"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print messages
print() {
    echo "$1"
}

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

print "🚀 Setting up Kafka with Strimzi on Kind"

# Check prerequisites
print "📋 Checking prerequisites..."

if ! command_exists kind; then
    print_error "kind is not installed. Please install kind first:"
    echo "  brew install kind"
    echo "  or visit: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi
print_status "kind is installed"

if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install kubectl first:"
    echo "  brew install kubectl"
    echo "  or visit: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi
print_status "kubectl is installed"

if ! command_exists docker; then
    print_error "Docker is not installed or not running. Please install and start Docker first."
    exit 1
fi
print_status "Docker is available"

# Check if cluster exists, reuse if present, else create
if kind get clusters | grep -q "$CLUSTER_NAME"; then
    print "Existing Kind cluster '$CLUSTER_NAME' found, reusing it."
    # Ensure kubectl context is set to the kind cluster
    kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null 2>&1 || kubectl config use-context "kind-$CLUSTER_NAME"
    print_status "Switched kubectl context to 'kind-$CLUSTER_NAME'"
else
    print "🏗️ Creating Kind cluster with 3 nodes..."
    kind create cluster --name "$CLUSTER_NAME" --config=manifests/kind-cluster.yaml
    print_status "Kind cluster '$CLUSTER_NAME' created"
    # Set kubectl context to the new cluster
    kubectl config use-context "kind-$CLUSTER_NAME"
    print_status "Kind cluster created with 3 nodes"
fi

# Wait for cluster to be ready
print "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
print_status "Cluster is ready"

# Create namespace if it doesn't exist
if ! kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print "📦 Creating namespace..."
    kubectl create namespace "$KAFKA_NAMESPACE"
    print_status "Namespace '$KAFKA_NAMESPACE' created"
fi

# Check if Strimzi operator is already installed
if ! kubectl get deployment strimzi-cluster-operator -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
    print
    print "🔧 Installing Strimzi operator..."
    kubectl create -f "https://strimzi.io/install/${STRIMZI_VERSION}?namespace=${KAFKA_NAMESPACE}" -n "$KAFKA_NAMESPACE"

    # Wait for Strimzi operator to be ready
    print "⏳ Waiting for Strimzi operator to be ready..."
    kubectl wait --for=condition=Ready pod -l name=strimzi-cluster-operator -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "Strimzi operator is ready"
fi

# Deploy Kafka cluster
print
print "🚀 Deploying Kafka cluster..."
kubectl apply -f manifests/kafka-cluster.yaml -n "$KAFKA_NAMESPACE"

# Wait for Kafka cluster to be ready
print "⏳ Waiting for Kafka cluster to be ready..."
kubectl wait --for=condition=Ready kafka kafka-cluster -n "$KAFKA_NAMESPACE" --timeout=600s
print_status "Kafka cluster is ready"

# Create test topic
print
print "📝 Creating test topic..."
kubectl apply -f manifests/kafka-topic.yaml -n "$KAFKA_NAMESPACE"
print "⏳ Waiting for topic to be ready..."
kubectl wait --for=condition=Ready kafkatopic test-topic -n "$KAFKA_NAMESPACE" --timeout=300s
print_status "Test topic created"

# Deploy Redpanda Console
print
print "🖥️  Deploying Redpanda Console..."
kubectl apply -f manifests/redpanda-console.yaml -n "$KAFKA_NAMESPACE"
print "⏳ Waiting for Redpanda Console to be ready..."
kubectl wait --for=condition=Available deployment/redpanda-console -n "$KAFKA_NAMESPACE" --timeout=300s
print_status "Redpanda Console is ready"

# Start demo data ingestion
print
print "📊 Starting demo data ingestion..."
kubectl apply -f manifests/demo-producer.yaml -n "$KAFKA_NAMESPACE"

print
echo -e "${GREEN}🎉 Setup complete!${NC}"
print
print "📋 Next steps:"
echo "1. Access Redpanda Console UI:"
echo "   kubectl port-forward service/redpanda-console 8080:8080 -n $KAFKA_NAMESPACE"
echo "   Then open http://localhost:8080 in your browser"
echo ""
echo "2. Port forward Kafka (for external clients):"
echo "   kubectl port-forward service/kafka-cluster-kafka-bootstrap 9092:9092 -n $KAFKA_NAMESPACE"
echo ""
echo "3. Check demo producer logs:"
echo "   kubectl logs -f deployment/demo-producer -n $KAFKA_NAMESPACE"
echo ""
echo "4. Consume messages via CLI:"
echo "   kubectl run kafka-consumer --image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0 --rm -it --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic test-topic --from-beginning"
echo ""
print "🧹 To clean up:"
echo "  ./cleanup.sh"
