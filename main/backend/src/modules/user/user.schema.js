// src/modules/user/user.schema.js

export const USER_SCHEMA = {
  bsonType: "object",
  title: "User Document Validation",
  required: ["email", "passwordHash", "creator", "name", "profile", "settings", "status", "createdAt", "updatedAt", "avatarUri", "bannerUri"],
  properties: {
    _id: {
      bsonType: "objectId"
    },
    customId: {
      bsonType: ["string", "null"],
    },
    email: {
      bsonType: "string",
    },
    creator: {
      bsonType: "bool",
    },
    name: {
      bsonType: "string",
    },
    passwordHash: {
      bsonType: "string",
    },
    avatarUri: {
      bsonType: ["string", "null"],
    },
    bannerUri: {
      bsonType: ["string", "null"],
    },
    profile: {
      bsonType: "object",
      required: ["gender", "bio"],
      properties: {
        gender: {
          bsonType: "object",
          required: ["type", "customValue"],
          properties: {
            type: {
              bsonType: "string",
              enum: ['male', 'female', 'unspecified', 'custom'],
            },
            customValue: {
              bsonType: "string",
              maxLength: 50,
            }
          },
          additionalProperties: false
        },
        bio: {
          bsonType: "string",
          maxLength: 175,
        }
      },
      additionalProperties: false
    },

    settings: {
      bsonType: "object",
      required: ["interface", "privacy"],
      properties: {
        interface: {
          bsonType: "object",
          required: ["hideGif"],
          properties: {
            hideGif: { bsonType: "bool" }
          },
          additionalProperties: false
        },
        privacy: {
          bsonType: "object",
          required: ["hideGender"],
          properties: {
            hideGender: { bsonType: "bool" }
          },
          additionalProperties: false
        }
      },
      additionalProperties: false
    },

    status: {
      bsonType: "object",
      required: ["isOnline", "lastSeen", "activeConnections", "activeTabs"],
      properties: {
        isOnline: { bsonType: "bool" },
        lastSeen: { bsonType: ["date", "null"] },
        activeConnections: { bsonType: "int", minimum: 0 },
        activeTabs: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["tabId", "isVisible"],
            properties: {
              tabId: { bsonType: "string" },
              isVisible: { bsonType: "bool" }
            },
            additionalProperties: false
          }
        }
      },
      additionalProperties: false
    },

    createdAt: { bsonType: "date" },
    updatedAt: { bsonType: "date" },
  },
  additionalProperties: false // prohibit all fields not specified above
};

// Definition of indices
export const USER_INDEXES = [
  // 1. Unique case-insensitive index for customId
  {
    key: { customId: 1 },
    options: { unique: true, sparse: true, name: 'customId_unique', collation: { locale: 'en', strength: 2 } }
  },
  // 2. Unique case-insensitive index for email
  {
    key: { email: 1 },
    options: { unique: true, name: 'email_unique', collation: { locale: 'en', strength: 2 } }
  },
  // 3. Indexes for status and activity
  { key: { 'status.isOnline': 1 } },
  { key: { 'status.lastSeen': 1 } },
  { key: { 'status.activeConnections': 1 } },
];