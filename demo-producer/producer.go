package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
	// "github.com/twmb/franz-go/pkg/sasl/plain" // Uncomment if SASL is needed
)

func main() {
	// Define command-line flags
	topic := flag.String("topic", "test-topic", "Kafka topic to produce messages to")
	messages := flag.Int("messages", 1000, "Number of messages to produce")
	delay := flag.Int("delay", 0, "Delay in milliseconds between each message")
	randomDelay := flag.Int("random-delay", 0, "Use random delay between 0 and specified delay (milliseconds)")

	// Parse command-line flags
	flag.Parse()

	// Create a Kafka client configuration with Manual partitioner
	seeds := []string{"kafka-cluster-kafka-bootstrap:9092"}

	// Uncomment for SASL authentication if needed
	// plainAuth := plain.Auth{
	//     User: "admin",
	//     Pass: "admin-secret",
	// }

	clientOpts := []kgo.Opt{
		kgo.SeedBrokers(seeds...),
		// kgo.SASL(plainAuth.AsMechanism()), // Uncomment if SASL is enabled

		kgo.AllowAutoTopicCreation(),
		kgo.RecordPartitioner(kgo.ManualPartitioner()),

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
		log.Printf("Failed to create topic %s: %v", result.Topic, result.Err)
	} else {
		log.Printf("Created topic %s", result.Topic)
	}

	for i := 0; i < *messages; i++ {
		// Create a context with a timeout per message
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
		defer cancel()

		// Create unbalanced partition distribution
		// 60% of messages go to partitions 0, 3, 6, 9 (15% each)
		// 40% of messages distributed across remaining 8 partitions (5% each)
		var partition int32
		randVal := rand.Intn(100)
		
		switch {
		case randVal < 15: // 15% to partition 0
			partition = 0
		case randVal < 30: // 15% to partition 3
			partition = 3
		case randVal < 45: // 15% to partition 6
			partition = 6
		case randVal < 60: // 15% to partition 9
			partition = 9
		case randVal < 65: // 5% to partition 1
			partition = 1
		case randVal < 70: // 5% to partition 2
			partition = 2
		case randVal < 75: // 5% to partition 4
			partition = 4
		case randVal < 80: // 5% to partition 5
			partition = 5
		case randVal < 85: // 5% to partition 7
			partition = 7
		case randVal < 90: // 5% to partition 8
			partition = 8
		case randVal < 95: // 5% to partition 10
			partition = 10
		default: // 5% to partition 11
			partition = 11
		}

		message := fmt.Sprintf("Hello, Kafka! Message %d", i+1)
		record := &kgo.Record{
			Topic:     *topic,
			Value:     []byte(message),
			Partition: partition,
		}

		client.BeginTransaction()
		// Produce the message
		err := client.ProduceSync(ctx, record).FirstErr()
		cancel() // Cancel the context to release resources

		if err != nil {
			log.Printf("failed to produce message: %v", err)
		} else {
			log.Printf("produced message to topic %s, partition %d: %s", *topic, partition, message)
		}

		// Delay between messages
		if *randomDelay > 0 {
			time.Sleep(time.Duration(rand.Intn(*randomDelay)) * time.Millisecond)
		} else if *delay > 0 {
			time.Sleep(time.Duration(*delay) * time.Millisecond)
		}
	}

	log.Println("Finished producing messages")
}
