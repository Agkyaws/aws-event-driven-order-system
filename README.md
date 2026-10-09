# AWS Event-Driven Order Processing (Terraform)

This project is a small event-driven order processing system built on AWS.  
It simulates an online order → payment → notification flow using serverless and messaging services.  
The infrastructure is created with Terraform.

---

## 1. Project Overview

The goal of this project is to show how to build an event-driven architecture on AWS:

- A client sends an order request.
- The system stores the order in a database.
- A background process handles the payment asynchronously.
- The system updates the order status and sends a notification when payment is successful.

This design separates the **API layer**, the **data layer**, and the **async processing layer**, which is a common pattern in modern cloud architectures.

---

## 2. Business Benefits

Even though this is a learning project, the architecture is close to what real businesses use in production.  
Here are the main business benefits:

### 2.1. Better User Experience

- The API responds quickly after the order is created, because payment is processed in the background.
- Users do not need to wait for the full payment process during the initial request.
- This reduces perceived latency and makes the application feel more responsive.

### 2.2. Higher Reliability and Resilience

- Using SQS and a dead-letter queue (`payment-dlq`) helps protect the system from failures:
  - If payment processing fails several times, the message is moved to the DLQ instead of blocking the whole system.
  - Problematic orders can be investigated separately without impacting other customers.
- Asynchronous processing and retries make the system more robust against temporary errors.

### 2.3. Scalability for Growing Traffic

- API Gateway and Lambda scale automatically with incoming requests.
- Payment processing is decoupled from the API, so the system can handle more orders by scaling the SQS + Lambda workers.
- This design can grow with the business without a complete redesign.

### 2.4. Clear Separation of Concerns

- The architecture separates:
  - Order creation (API + `CreateOrderFn`)
  - Data storage (DynamoDB)
  - Payment processing (SQS + `ProcessPaymentFn`)
  - Notifications (SNS + email)
- This makes the system easier to maintain and extend:
  - New payment methods or notification channels can be added without changing the core API.

### 2.5. Easier Monitoring and Troubleshooting

- Orders are stored in DynamoDB with clear statuses (`PENDING_PAYMENT`, `PAID`, `PAYMENT_FAILED`).
- Failed payment messages are stored in `payment-dlq`, which is useful for debugging and analysis.
- This improves visibility for support teams and reduces time to find and fix issues.

---

## 3. Architecture Summary

### Main AWS services

- **Amazon API Gateway**
  - REST API called `orders-api`.
  - Endpoints:
    - `POST /orders` – create a new order.
    - `GET /orders/{orderId}` – get the status of an order.

- **AWS Lambda**
  - `CreateOrderFn`
    - Handles `POST /orders`.
    - Validates the request and writes a new item into DynamoDB with `status = PENDING_PAYMENT`.
    - Does not send messages to SQS or SNS directly (no dual-write).
  - `GetOrderStatusFn`
    - Handles `GET /orders/{orderId}`.
    - Reads the order from DynamoDB and returns the current status.
  - `OrdersStreamToSqsFn`
    - Triggered by DynamoDB Streams on the `orders` table.
    - For new orders with `status = PENDING_PAYMENT`, sends a message to SQS `payment-queue`.
  - `ProcessPaymentFn`
    - Triggered by SQS `payment-queue`.
    - Simulates payment (for example, 80% success and 20% failure).
    - Updates the order status in DynamoDB to `PAID` or `PAYMENT_FAILED`.
    - When payment is successful, publishes a message to an SNS topic.

- **Amazon DynamoDB**
  - Table name: `orders`.
  - Partition key: `orderId` (string).
  - Streams enabled with `NEW_IMAGE` to capture new items.
  - Stores:
    - `orderId`, `customerId`, `amount`, `status`, `idempotencyKey`, `createdAt`.

- **Amazon SQS**
  - Main queue: `payment-queue`.
  - Dead-letter queue: `payment-dlq`.
  - `payment-queue` uses `payment-dlq` with `maxReceiveCount = 3`.
  - This means if a message fails 3 times, it is moved to the DLQ for later analysis.

- **Amazon SNS**
  - Topic: `order-notifications`.
  - Used to publish events when payment is successful.
  - A simple email subscription is attached (simulation only, not real SES setup).

---

## 4. Key Design Patterns

### Event-Driven Architecture

The system is not only request/response.  
After the order is created, the payment is processed asynchronously using messages and events:

- API Gateway + Lambda handle the HTTP requests.
- DynamoDB Streams, SQS, and Lambda handle the background processing.

### Outbox Pattern (with DynamoDB Streams)

To avoid “dual-write” problems (writing to the database and to a queue at the same time), the project uses an outbox-style approach:

1. `CreateOrderFn` writes the order to DynamoDB with `status = PENDING_PAYMENT`.
2. DynamoDB Streams detect the new record.
3. `OrdersStreamToSqsFn` reads the stream event and sends a message to `payment-queue`.

This ensures that an event is created **only after** the order is successfully stored in the database.

### Asynchronous Payment Processing

Payment is not processed during the API request.  
Instead:

- `OrdersStreamToSqsFn` sends a message to SQS.
- `ProcessPaymentFn` is triggered by SQS and simulates the payment.
- The order status is updated in DynamoDB later.

This makes the system more scalable and more resilient, because payment processing does not block the API response.

### Dead-Letter Queue (DLQ)

If `ProcessPaymentFn` fails to process a message several times:

- SQS moves the message from `payment-queue` to `payment-dlq`.
- Messages in `payment-dlq` can be inspected manually for debugging and analysis.
- This helps to isolate problematic messages and protect the main flow.

### Read API for Order Status

Clients can check the status of an order using:

- `GET /orders/{orderId}` → `GetOrderStatusFn` → DynamoDB.

This is a simple way to expose the current state of the order after the async processing is done.

---

## 5. Folder Structure

```text
.
├── main.tf
├── variables.tf
├── outputs.tf
├── lambda_create_order/
│   ├── index.js
│   └── index.zip
├── lambda_process_payment/
│   ├── index.js
│   └── index.zip
├── lambda_stream_to_sqs/
│   ├── index.js
│   └── index.zip
└── lambda_get_order_status/
│   ├── index.js
│   └── index.zip