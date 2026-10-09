// Simple Lambda to read DynamoDB Stream and send messages to SQS

const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

const sqs = new SQSClient({});
const PAYMENT_QUEUE_URL = process.env.PAYMENT_QUEUE_URL;

exports.handler = async (event) => {
  const promises = [];

  for (const record of event.Records) {
    try {
      // Simple check for INSERT event
      if (record.eventName !== "INSERT") {
        continue;
      }

      const newImage = record.dynamodb.NewImage;

      if (!newImage) {
        continue;
      }

      const status = newImage.status?.S;
      // Simple filter for PENDING_PAYMENT only
      if (status !== "PENDING_PAYMENT") {
        continue;
      }

      const orderId = newImage.orderId?.S;
      const customerId = newImage.customerId?.S;
      const amount = newImage.amount?.N;

      const messageBody = JSON.stringify({
        orderId,
        customerId,
        amount: amount ? Number(amount) : undefined,
      });

      const cmd = new SendMessageCommand({
        QueueUrl: PAYMENT_QUEUE_URL,
        MessageBody: messageBody,
      });

      promises.push(sqs.send(cmd));
    } catch (err) {
      console.error("Error in stream record processing:", err);
    }
  }

  // Simple parallel send
  await Promise.all(promises);

  return {
    statusCode: 200,
  };
};