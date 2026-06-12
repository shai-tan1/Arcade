// src/modules/game/engine/elo.js

const DEFAULT_K = 32;

export function expectedScore(ratingA, ratingB) {
    return 1 / (1 + Math.pow(10, (ratingB - ratingA) / 400));
}

// outcomeA: 1 = A wins, 0 = A loses, 0.5 = draw
export function newRating(ratingA, ratingB, outcomeA, k = DEFAULT_K) {
    return Math.round(ratingA + k * (outcomeA - expectedScore(ratingA, ratingB)));
}
