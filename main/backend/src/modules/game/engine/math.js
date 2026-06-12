// src/modules/game/engine/math.js
// Rapid-fire arithmetic: products, squares, roots, prime-factor questions.
// Every answer is a single integer, scored right/wrong. Speed breaks ties.

import { mulberry32 } from './prng.js';

const ROUNDS = 10;
const POINTS_PER_CORRECT = 10;
const PRIMES = [2, 3, 5, 7, 11, 13];

function randInt(rng, min, max) {
    return Math.floor(rng() * (max - min + 1)) + min;
}
function pick(rng, arr) {
    return arr[Math.floor(rng() * arr.length)];
}

function makeQuestion(rng) {
    const type = pick(rng, ['product', 'square', 'sqrt', 'largestPrime', 'sumPrime']);

    if (type === 'product') {
        const a = randInt(rng, 2, 19);
        const b = randInt(rng, 2, 19);
        return { text: `${a} × ${b}`, solution: a * b };
    }
    if (type === 'square') {
        const n = randInt(rng, 10, 39);
        return { text: `${n}²`, solution: n * n };
    }
    if (type === 'sqrt') {
        const n = randInt(rng, 4, 30);
        return { text: `√${n * n}`, solution: n };
    }
    if (type === 'largestPrime') {
        const k = randInt(rng, 2, 4);
        let N = 1;
        let maxP = 2;
        for (let i = 0; i < k; i++) {
            const p = pick(rng, PRIMES);
            N *= p;
            if (p > maxP) maxP = p;
        }
        return { text: `Largest prime factor of ${N}`, solution: maxP };
    }
    // sumPrime: sum of prime factors with multiplicity
    const k = randInt(rng, 2, 4);
    let N = 1;
    let sum = 0;
    for (let i = 0; i < k; i++) {
        const p = pick(rng, PRIMES);
        N *= p;
        sum += p;
    }
    return { text: `Sum of prime factors of ${N}`, solution: sum };
}

export const math = {
    key: 'math',
    rounds: ROUNDS,

    build(seed) {
        const rng = mulberry32(seed);
        const rounds = [];
        for (let i = 0; i < ROUNDS; i++) {
            const q = makeQuestion(rng);
            rounds.push({ prompt: { type: 'math', text: q.text }, solution: q.solution });
        }
        return rounds;
    },

    score(solution, answer) {
        const a = typeof answer === 'number' ? answer : parseInt(answer, 10);
        return Number.isFinite(a) && a === solution ? POINTS_PER_CORRECT : 0;
    }
};
