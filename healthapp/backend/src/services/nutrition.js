/**
 * Nutrient math. All nutrient values are derived from a nutrition database's per-100 g values
 * multiplied by grams — never from a model's guess.
 */
import { NUTRIENT_KEYS } from "../lib/schemas.js";

export { NUTRIENT_KEYS };

/**
 * @typedef {{ kcal?: number, proteinG?: number, carbsG?: number, fatG?: number, fiberG?: number, sugarG?: number, sodiumMg?: number }} Nutrients
 */

/** Display rounding: kcal and sodium to integers, grams to 0.1. */
export function roundNutrient(key, value) {
  if (value === undefined || value === null || !Number.isFinite(value)) return undefined;
  if (key === "kcal" || key === "sodiumMg") return Math.round(value);
  return Math.round(value * 10) / 10;
}

/** @param {Nutrients} n @returns {Nutrients} */
export function roundNutrients(n) {
  const out = {};
  for (const k of NUTRIENT_KEYS) {
    const r = roundNutrient(k, n?.[k]);
    if (r !== undefined) out[k] = r;
  }
  return out;
}

/**
 * Scale per-100 g nutrients to a portion.
 * @param {Nutrients} per100g @param {number} grams @returns {Nutrients}
 */
export function scaleNutrients(per100g, grams) {
  const out = {};
  const g = Math.max(0, Number(grams) || 0);
  for (const k of NUTRIENT_KEYS) {
    const val = per100g?.[k];
    if (typeof val === "number" && Number.isFinite(val)) out[k] = (val * g) / 100;
  }
  return roundNutrients(out);
}

/**
 * Sum nutrient maps (unrounded inputs are fine; output is rounded). Missing keys count as 0
 * only if at least one item has the key.
 * @param {Nutrients[]} list @returns {Nutrients}
 */
export function sumNutrients(list) {
  const out = {};
  for (const n of list) {
    for (const k of NUTRIENT_KEYS) {
      if (typeof n?.[k] === "number") out[k] = (out[k] ?? 0) + n[k];
    }
  }
  return roundNutrients(out);
}

/**
 * kcal range for a grams range.
 * @param {Nutrients} per100g @param {number} gramsLow @param {number} gramsHigh
 * @returns {{ kcalLow: number, kcalHigh: number } | undefined}
 */
export function kcalRange(per100g, gramsLow, gramsHigh) {
  if (typeof per100g?.kcal !== "number") return undefined;
  const lo = Math.min(gramsLow, gramsHigh);
  const hi = Math.max(gramsLow, gramsHigh);
  return { kcalLow: Math.round((per100g.kcal * lo) / 100), kcalHigh: Math.round((per100g.kcal * hi) / 100) };
}

/**
 * Compute an item's nutrients + kcal range from per-100 g values.
 * @param {Nutrients} per100g
 * @param {{ grams: number, gramsLow?: number, gramsHigh?: number }} portion
 */
export function computeItemNutrition(per100g, { grams, gramsLow, gramsHigh }) {
  const nutrients = scaleNutrients(per100g, grams);
  const range = kcalRange(per100g, gramsLow ?? grams, gramsHigh ?? grams) ?? { kcalLow: nutrients.kcal ?? 0, kcalHigh: nutrients.kcal ?? 0 };
  return { nutrients, range };
}

/**
 * Totals + kcal range over items (items without a range contribute their point kcal).
 * @param {{ nutrients?: Nutrients, range?: { kcalLow: number, kcalHigh: number } }[]} items
 */
export function totalsForItems(items) {
  const totals = sumNutrients(items.map((i) => i.nutrients ?? {}));
  let low = 0;
  let high = 0;
  for (const i of items) {
    const k = i.nutrients?.kcal ?? 0;
    low += i.range?.kcalLow ?? k;
    high += i.range?.kcalHigh ?? k;
  }
  return { totals, totalsRange: { kcalLow: Math.round(low), kcalHigh: Math.round(high) } };
}

/**
 * Server-side recomputation for a meal write (API: PUT /v1/meals → "server recomputes totals").
 * Weighed/user items get a collapsed range; `isEstimate` is true if any item is estimated.
 * @param {any} meal validated meal
 */
export function recomputeMeal(meal) {
  const items = meal.items.map((i) => {
    const kcal = i.nutrients?.kcal ?? 0;
    const collapse = i.weightSource === "scale" || i.weightSource === "label" || i.weightSource === "user";
    const range = collapse || !i.range ? { kcalLow: kcal, kcalHigh: kcal } : {
      kcalLow: Math.min(i.range.kcalLow ?? kcal, kcal),
      kcalHigh: Math.max(i.range.kcalHigh ?? kcal, kcal),
    };
    return { ...i, nutrients: roundNutrients(i.nutrients ?? {}), range };
  });
  const { totals, totalsRange } = totalsForItems(items);
  const isEstimate = items.some((i) => i.weightSource === "estimated");
  return { ...meal, items, totals, totalsRange, isEstimate };
}

/**
 * Per-100 g nutrients of a recipe from its items (uses cooked weight when known).
 * @param {{ items: { grams: number, nutrients?: Nutrients }[], totalCookedWeightG?: number }} recipe
 */
export function recipePer100g(recipe) {
  const totals = sumNutrients(recipe.items.map((i) => i.nutrients ?? {}));
  const weight = recipe.totalCookedWeightG || recipe.items.reduce((s, i) => s + (i.grams || 0), 0);
  if (!weight) return {};
  const out = {};
  for (const k of NUTRIENT_KEYS) if (typeof totals[k] === "number") out[k] = (totals[k] * 100) / weight;
  return roundNutrients(out);
}
