// src/modules/game/engine/colorGuess.js
// A color is shown; the player guesses its RGB values. Closest guess scores higher.

import { mulberry32 } from './prng.js';

const ROUNDS = 5;
const MAX_DIST = Math.sqrt(3 * 255 * 255); // max RGB euclidean distance

function genColor(rng) {
    return {
        r: Math.floor(rng() * 256),
        g: Math.floor(rng() * 256),
        b: Math.floor(rng() * 256)
    };
}

export const colorGuess = {
    key: 'colorGuess',
    rounds: ROUNDS,

    // Build all rounds deterministically from a seed.
    // For this game the shown color IS the solution (the player must see it to guess).
    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const target = genColor(rng);
            rounds.push({ prompt: { type: 'color', target }, solution: target });
        }
        return rounds;
    },

    // Score one guess against the solution: 0..100 (100 = exact).
    score(solution, answer) {
        if (!answer || typeof answer.r !== 'number' || typeof answer.g !== 'number' || typeof answer.b !== 'number') {
            return 0;
        }
        const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
        const dr = clamp(answer.r) - solution.r;
        const dg = clamp(answer.g) - solution.g;
        const db = clamp(answer.b) - solution.b;
        const dist = Math.sqrt(dr * dr + dg * dg + db * db);
        return Math.round(100 * (1 - dist / MAX_DIST));
    }
};
