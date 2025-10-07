# Kafka with Strimzi on Kind

A complete setup for running Apache Kafka locally using Kubernetes-in-Docker (Kind) with the Strimzi operator in KRaft mode.

If running using Colima, make sure you have enough resource, e.g.
```
colima start --memory 12 --cpu 6 --disk 100
```

## Prerequisites

Before running the setup, ensure you have the following installed:

- [Docker](https://docs.docker.com/get-docker/) - For running Kind
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) - Kubernetes in Docker
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - Kubernetes command-line tool

## Quick Start

Run
   ```bash
   ./setup.sh
   ```

Then follow instructions on e.g. port-forward to access RedPanda UI.

1. **View demo messages**:
   ```bash
   kubectl logs -f deployment/demo-producer -n kafka
   ```

1. **Consume messages**:
   ```bash
   kubectl run kafka-consumer --image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0 --rm -it --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic test-topic --from-beginning
   ```

## Rebalance cluster using Cruise Control

Create rebalance plan:
```
kubectl apply -f manifests/kafka-rebalance.yaml
```
After a while, it should say:
```
$ kubectl -n kafka get KafkaRebalance
NAME                CLUSTER         TEMPLATE   STATUS
cluster-rebalance   kafka-cluster              ProposalReady
```

Then approve proposals:
```
kubectl -n kafka annotate KafkaRebalance/cluster-rebalance strimzi.io/rebalance=approve
```

## Scale cluster

Modify number of replicas, then
```
$ kubectl -n kafka apply -f manifests/kafka-cluster.yaml
kafkanodepool.kafka.strimzi.io/broker configured
kafka.kafka.strimzi.io/kafka-cluster unchanged
kafkarebalance.kafka.strimzi.io/cluster-auto-rebalancing-template unchanged

$ kubectl -n kafka get kafkarebalance -w
NAME                                         CLUSTER         TEMPLATE   STATUS
cluster-auto-rebalancing-template                            true
kafka-cluster-auto-rebalancing-add-brokers   kafka-cluster              PendingProposal
kafka-cluster-auto-rebalancing-add-brokers   kafka-cluster              ProposalReady
kafka-cluster-auto-rebalancing-add-brokers   kafka-cluster              Rebalancing
kafka-cluster-auto-rebalancing-add-brokers   kafka-cluster              Ready
```

## Useful Commands

### Check cluster status
```bash
kubectl get pods -n kafka
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka
```

### View logs
```bash
# Strimzi operator logs
kubectl logs -f deployment/strimzi-cluster-operator -n kafka

# Demo producer logs
kubectl logs -f deployment/demo-producer -n kafka

# Kafka broker logs
kubectl logs -f kafka-cluster-kafka-0 -n kafka
```

### Create additional topics
```bash
# Create a new topic manifest
cat > manifests/my-topic.yaml <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  namespace: kafka
  labels:
    strimzi.io/cluster: kafka-cluster
spec:
  partitions: 3
  replicas: 3
EOF

# Apply the topic
kubectl apply -f manifests/my-topic.yaml
```

### Produce messages manually
```bash
kubectl run kafka-producer --image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0 --rm -it --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic test-topic
```
