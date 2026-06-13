// src/modules/hashtag/hashtag.controller.js

import { getDB } from '../../core/engine/db/connectDB.js';
import { handleServerError } from '../../shared/helpers/index.js';

const hashtags = () => getDB().collection('hashtags');

export const getHashtags = async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 6;
 
    const aggregationPipeline = [
      // 1. Grouping and counting the number of posts for each hashtag
      { $group: { _id: "$name", quantity: { $count: {} } } },

      // 2. Sort: first by quantity (DESC), then by name (ASC)
      { $sort: { quantity: -1, _id: 1 } },

      // 3. Limiting the overall result
      { $limit: limit },

      // 4. Projecting the result into the desired format
      { $project: { name: "$_id", quantity: "$quantity", _id: 0 } }
    ];

    // Perform aggregation and convert the cursor to an array
    const result = await hashtags().aggregate(aggregationPipeline).toArray();

    return res.status(200).json(result);
  } catch (error) {
    handleServerError(res, error);
  }
};