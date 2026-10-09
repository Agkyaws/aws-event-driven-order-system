// Simple Lambda to get order status from DynamoDB

const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");

const ddb = new DynamoDBClient({});
const TABLE_NAME = process.env.ORDERS_TABLE_NAME;

const s = (value) => ({ S: value });

exports.handler = async (event) => {
  try {
    // Simple path parameter read
    const orderId = event.pathParameters?.orderId;

    if (!orderId) {
      return {
        statusCode: 400,
        body: JSON.stringify({ message: "Missing orderId in path" }),
      };
    }

    const cmd = new GetItemCommand({
      TableName: TABLE_NAME,
      Key: { orderId: s(orderId) },
    });

    const result = await ddb.send(cmd);

    if (!result.Item) {
      return {
        statusCode: 404,
        body: JSON.stringify({ message: "Order not found" }),
      };
    }

    // Simple mapping from DynamoDB item to JSON
    const item = result.Item;

    const response = {
      orderId: item.orderId?.S,
      customerId: item.customerId?.S,
      amount: item.amount?.N ? Number(item.amount.N) : undefined,
      status: item.status?.S,
      createdAt: item.createdAt?.S,
    };

    return {
      statusCode: 200,
      body: JSON.stringify(response),
    };
  } catch (err) {
    console.error("Error in GetOrderStatusFn:", err);
    return {
      statusCode: 500,
      body: JSON.stringify({ message: "Internal server error" }),
    };
  }
};