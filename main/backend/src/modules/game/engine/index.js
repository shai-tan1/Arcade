// src/modules/game/engine/index.js
// Registry of playable games. Add new games here as they are implemented.

import { colorGuess } from './colorGuess.js';
import { math } from './math.js';

export const GAME_ENGINES = {
    colorGuess,
    math
};

export function getEngine(gameType) {
    return GAME_ENGINES[gameType] || null;
}
