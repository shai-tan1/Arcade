// src/modules/game/engine/frequency.js
// A tone is played; the player guesses its frequency in Hz. Closest guess scores higher.

import { mulberry32 } from './prng.js';

const ROUNDS = 5;
const MIN_HZ = 120;
const MAX_HZ = 3000;
const MAX_OCTAVES = 2; // beyond ~2 octaves off = 0 points

function genFreq(rng) {
    // log-uniform pick so low/high tones are equally likely perceptually
    return Math.round(MIN_HZ * Math.pow(MAX_HZ / MIN_HZ, rng()));
}

export const frequency = {
    key: 'frequency',
    rounds: ROUNDS,

    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const target = genFreq(rng);
            // The tone (target) is sent so the client can play it; the guess is scored against it.
            rounds.push({ prompt: { type: 'frequency', target }, solution: target });
        }
        return rounds;
    },

    score(solution, answer) {
        const g = typeof answer === 'number' ? answer : parseFloat(answer);
        if (!Number.isFinite(g) || g <= 0) return 0;
        const octaves = Math.abs(Math.log2(g / solution));
        return Math.round(Math.max(0, 100 * (1 - octaves / MAX_OCTAVES)));
    }
};
