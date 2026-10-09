// Simple Lambda for processing payment from SQS and updating DynamoDB

const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");

const ddb = new DynamoDBClient({});
const sns = new SNSClient({});

const TABLE_NAME = process.env.ORDERS_TABLE_NAME;
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;
const PAYMENT_SUCCESS_RATE = parseFloat(process.env.PAYMENT_SUCCESS_RATE || "0.8");

// Simple helper
const s = (value) => ({ S: value });

exports.handler = async (event) => {
  // Simple array to track failed messages for partial batch failure
  const batchItemFailures = [];

  for (const record of event.Records) {
    const messageId = record.messageId;
    try {
      // Simple message body parsing
      const body = JSON.parse(record.body);

      const orderId = body.orderId;
      const amount = body.amount;
      const customerId = body.customerId;

      if (!orderId) {
        // Simple validation failure
        batchItemFailures.push({ itemIdentifier: messageId });
        continue;
      }

      // Simple payment simulation
      const random = Math.random();
      const paymentSucceeded = random < PAYMENT_SUCCESS_RATE;

      const newStatus = paymentSucceeded ? "PAID" : "PAYMENT_FAILED";

      // Simple DynamoDB update
      const updateCmd = new UpdateItemCommand({
        TableName: TABLE_NAME,
        Key: { orderId: s(orderId) },
        UpdateExpression: "SET #status = :status",
        ExpressionAttributeNames: {
          "#status": "status",
        },
        ExpressionAttributeValues: {
          ":status": s(newStatus),
        },
      });

      await ddb.send(updateCmd);

      // Simple SNS publish only on success
      if (paymentSucceeded) {
        const message = {
          orderId,
          customerId,
          amount,
          status: newStatus,
        };

        const publishCmd = new PublishCommand({
          TopicArn: SNS_TOPIC_ARN,
          Message: JSON.stringify(message),
          Subject: "Order Payment Successful",
        });

        await sns.send(publishCmd);
      }
    } catch (err) {
      console.error("Error processing SQS message:", err);
      // Simple failure tracking for partial batch
      batchItemFailures.push({ itemIdentifier: messageId });
    }
  }

  // Simple partial batch failure response
  return {
    batchItemFailures,
  };
};