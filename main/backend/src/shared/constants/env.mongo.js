// env.mongo.js
export const BASE_URI = process.env.MONGO_BASE_URI;
export const HOST = process.env.MONGO_HOST;
export const PORT = process.env.MONGO_PORT;
export const DB_NAME = process.env.MONGO_DB_NAME;
export const USER = encodeURIComponent(process.env.MONGO_USER);
export const PASSWORD = encodeURIComponent(process.env.MONGO_PASSWORD);
export const AUTH_SOURCE = process.env.MONGO_AUTH_SOURCE || "admin"; 