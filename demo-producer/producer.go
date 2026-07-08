package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
	// "github.com/twmb/franz-go/pkg/sasl/plain" // Uncomment if SASL is needed
)

// batchLogger implements kgo.HookProduceBatchWritten so we can see the batching
// that linger.ms produces: it fires once per record batch actually sent to a
// broker, reporting how many records were coalesced and the wire size.
type batchLogger struct{}

func (batchLogger) OnProduceBatchWritten(meta kgo.BrokerMetadata, topic string, partition int32, m kgo.ProduceBatchMetrics) {
	log.Printf("batch written: broker=%d topic=%s partition=%d records=%d bytes=%d (uncompressed=%d)",
		meta.NodeID, topic, partition, m.NumRecords, m.CompressedBytes, m.UncompressedBytes)
}

func main() {
	// Define command-line flags
	topic := flag.String("topic", "test-topic", "Kafka topic to produce messages to")
	messages := flag.Int("messages", 1000, "Number of messages to produce")
	delay := flag.Int("delay", 0, "Delay in milliseconds between each message")
	randomDelay := flag.Int("random-delay", 0, "Use random delay between 0 and specified delay (milliseconds)")
	startFrom := flag.Int("start-from", 0, "First message number to start from")
	brokers := flag.String("brokers", "kafka-cluster-kafka-bootstrap:9092", "Comma-separated Kafka bootstrap brokers")
	lingerMs := flag.Int("linger-ms", 250, "linger.ms: max time (ms) to accumulate records into a batch before sending")

	// Parse command-line flags
	flag.Parse()

	// Create a Kafka client configuration with Manual partitioner
	seeds := strings.Split(*brokers, ",")

	// Uncomment for SASL authentication if needed
	// plainAuth := plain.Auth{
	//     User: "admin",
	//     Pass: "admin-secret",
	// }

	clientOpts := []kgo.Opt{
		kgo.SeedBrokers(seeds...),
		// kgo.SASL(plainAuth.AsMechanism()), // Uncomment if SASL is enabled

		kgo.AllowAutoTopicCreation(),

		// linger.ms: wait up to --linger-ms to accumulate records into a single
		// batch per partition before sending, trading latency for throughput.
		// The async produce loop below lets records pile up during this window,
		// so raising/lowering this value visibly changes batch sizes (see the
		// "batch written" logs from batchLogger).
		kgo.ProducerLinger(time.Duration(*lingerMs) * time.Millisecond),

		// Log every batch as it is written so batching is observable.
		kgo.WithHooks(batchLogger{}),

		// only require leader ack, so we can still produce if a broker is down
		// allows us to test taking down brokers
		kgo.RequiredAcks(kgo.LeaderAck()),

		// disabling idempotency means that Kafka will not guarantee exactly-once delivery,
		// since we're not requiring all acks
		// (idempotency = repeating operation gives same result)
		kgo.DisableIdempotentWrite(),
	}

	client, err := kgo.NewClient(clientOpts...)
	if err != nil {
		log.Fatalf("unable to create kafka client: %v", err)
	}
	defer client.Close()

	// Create a Kafka admin client
	adminClient := kadm.NewClient(client)

	// Create topic with 12 partitions and 3 replicas
	partitions := int32(12)
	replication := int16(3)

	// Create the topic
	result, err := adminClient.CreateTopic(context.Background(), partitions, replication, nil, *topic)
	if err != nil {
		if !strings.HasPrefix(err.Error(), "TOPIC_ALREADY_EXISTS") {
			log.Fatalf("failed to create topic: %v", err.Error())
		}
	}
	if result.Err != nil {
		log.Printf("[INF] Unable to create topic %s: %v", result.Topic, result.Err)
	} else {
		log.Printf("Created topic %s", result.Topic)
	}

	// Produce asynchronously so records can accumulate into batches during the
	// linger window. Completion runs in the client's callback goroutines, so the
	// progress counters are guarded by a mutex. Throttle progress logging: print
	// at most once per 1000 messages or every 10 seconds, whichever comes first.
	var (
		mu           sync.Mutex
		produced     int
		failed       int
		lastLogCount int
		lastLogTime  = time.Now()
	)

	// A single long-lived context for all records: cancelling per-record (as the
	// old ProduceSync loop did) would abort still-buffered records mid-batch.
	ctx := context.Background()

	for i := 0; i < *messages; i++ {
		message := fmt.Sprintf("Hello, Kafka! Message %d", *startFrom+i)
		record := &kgo.Record{
			Topic: *topic,
			Value: []byte(message),
		}

		client.Produce(ctx, record, func(r *kgo.Record, err error) {
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failed++
				log.Printf("failed to produce message: %v", err)
				return
			}
			produced++
			if produced-lastLogCount >= 1000 || time.Since(lastLogTime) >= 10*time.Second {
				log.Printf("produced %d messages to topic %s (latest: %s)", produced, *topic, string(r.Value))
				lastLogCount = produced
				lastLogTime = time.Now()
			}
		})

		// Delay between messages. Note: any delay spreads records out in time and
		// works against batching — use 0 (the default) to see linger.ms batch.
		if *randomDelay > 0 {
			time.Sleep(time.Duration(rand.Intn(*randomDelay)) * time.Millisecond)
		} else if *delay > 0 {
			time.Sleep(time.Duration(*delay) * time.Millisecond)
		}
	}

	// Block until all buffered records have been sent (or failed).
	if err := client.Flush(ctx); err != nil {
		log.Printf("flush error: %v", err)
	}

	mu.Lock()
	log.Printf("Finished producing messages: %d succeeded, %d failed", produced, failed)
	mu.Unlock()
}
