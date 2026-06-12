// src/core/engine/db/connectDB.js 

import { MongoClient } from "mongodb";
import { initializeCollections } from "./initializeCollections.js";
import {
    BASE_URI,
    HOST,
    PORT,
    DB_NAME,
    USER,
    PASSWORD,
    AUTH_SOURCE,
    PRODUCTION_STATUS
} from "../../../shared/constants/index.js";

const maxRetries = 5;
const retryDelay = 2000; // ms

let dbClient = null;

const orangeBox = (text) => `\x1b[48;5;202m\x1b[38;2;255;255;255m${text}\x1b[0m`;

export function getDB() {
    if (!dbClient) {
        throw new Error("Database connection not established. Call connectDB first.");
    }
    return dbClient.db(DB_NAME);
}

export async function connectDB(retries = maxRetries) {
    if (dbClient) {
        console.log(` ✅ MongoDB already connected.`);
        return;
    }

    const clientUri = BASE_URI
        ? BASE_URI
        : `mongodb://${USER}:${PASSWORD}@${HOST}:${PORT}/?authSource=${AUTH_SOURCE}`;

    const mongoLogUri = BASE_URI
        ? DB_NAME
        : `${HOST}:${PORT}/${DB_NAME}`;

    console.log(` 🔌 Connecting to MongoDB at: ${mongoLogUri}...`);

    try {
        const client = new MongoClient(clientUri, {
            serverSelectionTimeoutMS: 5000,
        });

        await client.connect();
        dbClient = client;

        // Initializing collections and indexes
        await initializeCollections(dbClient.db(DB_NAME));

        console.log(` ${orangeBox(`MongoDB `)}
  Status: ОК 
  Connected: ${mongoLogUri}`
        );

    } catch (error) {
        console.error(` ❌ DB connection failed (${maxRetries - retries + 1}/${maxRetries}) -`, error.message);

        if (retries > 0) {
            console.log(` 🔁 Retrying in ${retryDelay / 1000}s...\n`);
            await new Promise(resolve => setTimeout(resolve, retryDelay));
            await connectDB(retries - 1);
        } else {
            console.error(" ❌ All retry attempts failed. Exiting.\n");
            process.exit(1);
        }
    }
}