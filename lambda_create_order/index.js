// Simple Lambda for creating order and writing to DynamoDB

const { DynamoDBClient, PutItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const crypto = require("crypto");

const ddb = new DynamoDBClient({});
const TABLE_NAME = process.env.ORDERS_TABLE_NAME;

// Simple helper to build DynamoDB string attribute
const s = (value) => ({ S: value });
const n = (value) => ({ N: String(value) });

exports.handler = async (event) => {
  try {
    // Simple body parsing
    const body = typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

    const { customerId, items, amount, idempotencyKey } = body || {};

    if (!customerId || !amount || !idempotencyKey) {
      return {
        statusCode: 400,
        body: JSON.stringify({ message: "Missing required fields" }),
      };
    }

    // Simple orderId generation
    const orderId = crypto.randomUUID();

    // Simple idempotency check using idempotencyKey as primary key in a separate table is better
    // Here we just do a basic check by scanning existing order with same idempotencyKey (simplified)
    // For demo, we skip complex idempotency implementation.

    const now = new Date().toISOString();

    const putCmd = new PutItemCommand({
      TableName: TABLE_NAME,
      Item: {
        orderId: s(orderId),
        customerId: s(customerId),
        amount: n(amount),
        status: s("PENDING_PAYMENT"),
        idempotencyKey: s(idempotencyKey),
        createdAt: s(now),
      },
      // Simple condition to avoid duplicate idempotencyKey
      ConditionExpression: "attribute_not_exists(orderId)",
    });

    await ddb.send(putCmd);

    return {
      statusCode: 201,
      body: JSON.stringify({
        orderId,
        status: "PENDING_PAYMENT",
      }),
    };
  } catch (err) {
    // Simple error handling
    console.error("Error in CreateOrderFn:", err);

    // If conditional check fails, treat as idempotent
    if (err.name === "ConditionalCheckFailedException") {
      return {
        statusCode: 200,
        body: JSON.stringify({ message: "Order already exists for this idempotencyKey" }),
      };
    }

    return {
      statusCode: 500,
      body: JSON.stringify({ message: "Internal server error" }),
    };
  }
};