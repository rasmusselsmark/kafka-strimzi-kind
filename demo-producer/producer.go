package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
	// "github.com/twmb/franz-go/pkg/sasl/plain" // Uncomment if SASL is needed
)

// batchStats implements kgo.HookProduceBatchWritten so we can see the batching
// that linger.ms produces: the hook fires once per record batch actually sent to
// a broker. Each call logs the batch and accumulates totals for the end-of-run
// summary. The hook runs on the client's goroutines, so access is mutex-guarded.
type batchStats struct {
	verbose           bool // when true, log every batch as it is written
	mu                sync.Mutex
	batches           int64
	records           int64
	compressedBytes   int64 // bytes on the wire (post-compression)
	uncompressedBytes int64 // raw record bytes
	minRecords        int
	maxRecords        int
}

func (b *batchStats) OnProduceBatchWritten(meta kgo.BrokerMetadata, topic string, partition int32, m kgo.ProduceBatchMetrics) {
	b.mu.Lock()
	if b.batches == 0 || m.NumRecords < b.minRecords {
		b.minRecords = m.NumRecords
	}
	if m.NumRecords > b.maxRecords {
		b.maxRecords = m.NumRecords
	}
	b.batches++
	b.records += int64(m.NumRecords)
	b.compressedBytes += int64(m.CompressedBytes)
	b.uncompressedBytes += int64(m.UncompressedBytes)
	b.mu.Unlock()

	if b.verbose {
		log.Printf("batch written: broker=%d topic=%s partition=%d records=%d bytes=%d (uncompressed=%d)",
			meta.NodeID, topic, partition, m.NumRecords, m.CompressedBytes, m.UncompressedBytes)
	}
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
	verbose := flag.Bool("verbose", false, "Log every batch as it is written (in addition to the end-of-run summary)")

	// Parse command-line flags
	flag.Parse()

	// Create a Kafka client configuration with Manual partitioner
	seeds := strings.Split(*brokers, ",")

	// Accumulates per-batch metrics for the end-of-run summary.
	stats := &batchStats{verbose: *verbose}

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

		// Log every batch as it is written and accumulate batch stats.
		kgo.WithHooks(stats),

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

	// stopCtx is cancelled on SIGTERM/SIGINT. Kubernetes stops a pod by sending
	// SIGTERM and waiting terminationGracePeriodSeconds (default 30s) before
	// SIGKILL. signal.NotifyContext replaces the default "terminate immediately"
	// behaviour with a context cancel, so we can stop enqueuing and flush the
	// linger buffer before exiting — otherwise records still buffered for up to
	// linger.ms would be lost on shutdown.
	stopCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Records are produced with a background context, NOT stopCtx: cancelling the
	// produce context would abort still-buffered records mid-batch (the very data
	// loss we are trying to avoid). We stop by breaking the loop, then flushing.
	produceCtx := context.Background()

	start := time.Now()
	interrupted := false

	for i := 0; i < *messages; i++ {
		if stopCtx.Err() != nil {
			interrupted = true
			log.Printf("shutdown signal received after enqueuing %d messages; draining buffer...", i)
			break
		}

		message := fmt.Sprintf("Hello, Kafka! Message %d", *startFrom+i)
		record := &kgo.Record{
			Topic: *topic,
			Value: []byte(message),
		}

		client.Produce(produceCtx, record, func(r *kgo.Record, err error) {
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
		// The sleep is interruptible so shutdown stays prompt during --delay runs.
		var d time.Duration
		if *randomDelay > 0 {
			d = time.Duration(rand.Intn(*randomDelay)) * time.Millisecond
		} else if *delay > 0 {
			d = time.Duration(*delay) * time.Millisecond
		}
		if d > 0 {
			select {
			case <-time.After(d):
			case <-stopCtx.Done():
			}
		}
	}

	// Drain the buffer. Use a fresh, bounded context — NOT stopCtx, which is
	// already cancelled on shutdown (Flush returns immediately on a cancelled
	// context and would drop the buffer). The timeout stays within the pod's
	// termination grace period so Flush can't outlive SIGKILL.
	flushCtx, cancelFlush := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancelFlush()
	if err := client.Flush(flushCtx); err != nil {
		log.Printf("flush error (some records may not have been delivered): %v", err)
	}
	elapsed := time.Since(start)

	mu.Lock()
	okCount, failCount := produced, failed
	mu.Unlock()

	stats.mu.Lock()
	batches, records := stats.batches, stats.records
	comp, uncomp := stats.compressedBytes, stats.uncompressedBytes
	minR, maxR := stats.minRecords, stats.maxRecords
	stats.mu.Unlock()

	secs := elapsed.Seconds()
	log.Printf("Finished producing messages: %d succeeded, %d failed", okCount, failCount)

	fmt.Println()
	fmt.Println("──────────────── run summary ────────────────")
	fmt.Printf("  linger.ms            : %d\n", *lingerMs)
	if interrupted {
		fmt.Printf("  shutdown             : interrupted by signal (buffer flushed)\n")
	}
	fmt.Printf("  messages             : %d ok, %d failed\n", okCount, failCount)
	fmt.Printf("  elapsed              : %.2fs\n", secs)
	if secs > 0 {
		fmt.Printf("  throughput           : %.0f msg/s\n", float64(okCount)/secs)
	}
	fmt.Printf("  batches written      : %d\n", batches)
	if batches > 0 {
		fmt.Printf("  records/batch        : avg %.1f (min %d, max %d)\n",
			float64(records)/float64(batches), minR, maxR)
		fmt.Printf("  bytes/batch (wire)   : avg %.0f\n", float64(comp)/float64(batches))
	}
	fmt.Printf("  wire bytes           : %.2f MB", float64(comp)/1e6)
	if secs > 0 {
		fmt.Printf(" (%.2f MB/s)", float64(comp)/1e6/secs)
	}
	fmt.Println()
	fmt.Printf("  uncompressed bytes   : %.2f MB\n", float64(uncomp)/1e6)
	if comp > 0 {
		fmt.Printf("  compression ratio    : %.2fx\n", float64(uncomp)/float64(comp))
	}
	fmt.Println("─────────────────────────────────────────────")
}
