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

# Check prerequisites
check_prerequisites() {
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

    if ! command_exists helm; then
        print_error "Helm is not installed. Please install Helm first:"
        echo "  brew install helm"
        echo "  or visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    print_status "Helm is installed"
}

# Setup Kind cluster
setup_kind_cluster() {
    # Check if cluster exists, reuse if present, else create
    if kind get clusters | grep -q "$CLUSTER_NAME"; then
        print "Existing Kind cluster '$CLUSTER_NAME' found, reusing it."
        # Ensure kubectl context is set to the kind cluster
        kubectl config use-context "kind-$CLUSTER_NAME"
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
}

# Create namespace
create_namespace() {
    if ! kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        print "📦 Creating namespace..."
        kubectl create namespace "$KAFKA_NAMESPACE"
        print_status "Namespace '$KAFKA_NAMESPACE' created"
    fi
}

# Install Strimzi operator
install_strimzi_operator() {
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
}

# Deploy Kafka cluster
deploy_kafka_cluster() {
    print
    print "🚀 Deploying Kafka cluster..."
    kubectl apply -f manifests/kafka-cluster.yaml -n "$KAFKA_NAMESPACE"

    # Wait for Kafka cluster to be ready
    print "⏳ Waiting for Kafka cluster to be ready..."
    kubectl wait --for=condition=Ready kafka kafka-cluster -n "$KAFKA_NAMESPACE" --timeout=600s
    print_status "Kafka cluster is ready"
}

# Create test topic
create_test_topic() {
    print
    print "📝 Creating test topic..."
    kubectl apply -f manifests/kafka-topic.yaml -n "$KAFKA_NAMESPACE"
    print "⏳ Waiting for topic to be ready..."
    kubectl wait --for=condition=Ready kafkatopic test-topic -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "Test topic created"
}

# Build and load demo producer image
build_and_load_demo_producer() {
    print
    print "🔨 Building demo producer Docker image..."
    cd demo-producer
    docker build -t kafka-demo-producer:latest . >/dev/null 2>&1
    cd ..
    print_status "Demo producer image built"

    print "📦 Loading image into Kind cluster..."
    kind load docker-image kafka-demo-producer:latest --name "$CLUSTER_NAME" >/dev/null 2>&1
    print_status "Image loaded into Kind cluster"
}

# Deploy Redpanda Console
deploy_redpanda_console() {
    print
    print "🖥️  Deploying Redpanda Console..."
    kubectl apply -f manifests/redpanda-console.yaml -n "$KAFKA_NAMESPACE"
    print "⏳ Waiting for Redpanda Console to be ready..."
    kubectl wait --for=condition=Available deployment/redpanda-console -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "Redpanda Console is ready"
}

# Start demo data ingestion
start_demo_data_ingestion() {
    print
    print "📊 Starting demo data ingestion..."
    kubectl apply -f manifests/demo-producer.yaml -n "$KAFKA_NAMESPACE"
}

# Install KMinion for monitoring
install_kminion() {
    print
    print "📊 Installing KMinion for Kafka monitoring..."
    # Add Redpanda Helm repository
    helm repo add redpanda https://charts.redpanda.com/ >/dev/null 2>&1
    helm repo update >/dev/null 2>&1
    print_status "Redpanda Helm repository added"

    # Install KMinion with custom values
    helm upgrade --install kminion redpanda/kminion \
      --namespace "$KAFKA_NAMESPACE" \
      --values manifests/kminion-values.yaml \
      --wait \
      --timeout=300s >/dev/null 2>&1

    print "⏳ Waiting for KMinion to be ready..."
    kubectl wait --for=condition=Available deployment/kminion -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "KMinion is ready"
}

# Install Prometheus Operator for monitoring
install_prometheus_operator() {
    print
    print "📊 Installing Prometheus Operator for metrics collection..."
    # Add Prometheus Community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
    helm repo update >/dev/null 2>&1
    print_status "Prometheus Community Helm repository added"

    # Install Prometheus Operator
    # The `prometheus.prometheusSpec` values are required for discovering KMinion metrics using custom ServiceMonitor.
    helm upgrade --install prometheus-operator prometheus-community/kube-prometheus-stack \
      --namespace "$KAFKA_NAMESPACE" \
      --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
      --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
      --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
      --set grafana.enabled=false \
      --wait \
      --timeout=300s >/dev/null 2>&1

    print "⏳ Waiting for Prometheus Operator to be ready..."
    kubectl wait --for=condition=Available deployment/prometheus-operator-kube-p-operator -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "Prometheus Operator is ready"
}

# Deploy ServiceMonitor for KMinion
deploy_servicemonitor() {
    print
    print "📊 Deploying ServiceMonitor for KMinion..."
    kubectl apply -f manifests/kminion-servicemonitor.yaml -n "$KAFKA_NAMESPACE"

    print "⏳ Waiting for Prometheus to be ready..."
    kubectl wait --for=condition=Available prometheus/prometheus-operator-kube-p-prometheus -n "$KAFKA_NAMESPACE" --timeout=300s
    print_status "Prometheus is ready"
}

# Print completion message
print_completion_message() {
    print
    echo -e "${GREEN}🎉 Setup complete!${NC}"
    print
    print "📋 Next steps:"
    echo "1. Access Redpanda Console UI:"
    echo "   kubectl -n $KAFKA_NAMESPACE port-forward service/redpanda-console 8080:8080"
    echo "   Then open http://localhost:8080 in your browser"
    echo ""
    echo "2. Access Prometheus UI:"
    echo "   kubectl -n $KAFKA_NAMESPACE port-forward service/prometheus-operator-kube-p-prometheus 9090:9090"
    echo "   Then open http://localhost:9090 in your browser"
    echo ""
    echo "3. Access KMinion metrics directly:"
    echo "   kubectl -n $KAFKA_NAMESPACE port-forward service/kminion 8081:8080"
    echo "   Then open http://localhost:8081/metrics in your browser"
    echo ""
    echo "4. Port forward Kafka (for external clients):"
    echo "   kubectl -n $KAFKA_NAMESPACE port-forward service/kafka-cluster-kafka-bootstrap 9092:9092"
    echo ""
    echo "5. Check demo producer logs:"
    echo "   kubectl -n $KAFKA_NAMESPACE logs -f deployment/demo-producer"
    echo ""
    echo "6. Check KMinion logs:"
    echo "   kubectl -n $KAFKA_NAMESPACE logs -f deployment/kminion"
    echo ""
    echo "7. Check Prometheus logs:"
    echo "   kubectl -n $KAFKA_NAMESPACE logs -f deployment/prometheus-operator-kube-p-prometheus"
    echo ""
    echo "8. Consume messages via CLI:"
    echo "   kubectl -n $KAFKA_NAMESPACE run kafka-consumer --image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0 --rm -it --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic test-topic --from-beginning"
    echo ""
    print "🧹 To clean up:"
    echo "  ./cleanup.sh"
}

# Main function
main() {
    print "🚀 Setting up Kafka with Strimzi on Kind"

    check_prerequisites
    setup_kind_cluster
    create_namespace
    install_strimzi_operator
    deploy_kafka_cluster
    create_test_topic
    build_and_load_demo_producer
    deploy_redpanda_console
    install_kminion
    install_prometheus_operator
    deploy_servicemonitor
    start_demo_data_ingestion
    print_completion_message
}

# Run main function
main
