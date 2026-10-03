import { test } from "node:test";
import assert from "node:assert/strict";
import { computeItemNutrition, kcalRange, recomputeMeal, recipePer100g, scaleNutrients, sumNutrients, totalsForItems } from "../src/services/nutrition.js";
import { normalizeNutrients } from "../src/services/usda.js";
import { mapOffProduct } from "../src/services/openfoodfacts.js";

const RICE = { kcal: 130, proteinG: 2.69, carbsG: 28.17, fatG: 0.28, fiberG: 0.4, sugarG: 0.05, sodiumMg: 1 };

test("scaleNutrients multiplies per-100 g values by grams/100 and rounds", () => {
  assert.deepEqual(scaleNutrients(RICE, 180), { kcal: 234, proteinG: 4.8, carbsG: 50.7, fatG: 0.5, fiberG: 0.7, sugarG: 0.1, sodiumMg: 2 });
  assert.deepEqual(scaleNutrients(RICE, 0), { kcal: 0, proteinG: 0, carbsG: 0, fatG: 0, fiberG: 0, sugarG: 0, sodiumMg: 0 });
});

test("kcalRange follows the grams range and orders bounds", () => {
  assert.deepEqual(kcalRange(RICE, 130, 240), { kcalLow: 169, kcalHigh: 312 });
  assert.deepEqual(kcalRange(RICE, 240, 130), { kcalLow: 169, kcalHigh: 312 });
  assert.equal(kcalRange({}, 1, 2), undefined);
});

test("computeItemNutrition collapses range when no grams range given", () => {
  const r = computeItemNutrition(RICE, { grams: 100 });
  assert.deepEqual(r.range, { kcalLow: 130, kcalHigh: 130 });
});

test("sumNutrients and totalsForItems", () => {
  assert.deepEqual(sumNutrients([{ kcal: 100, proteinG: 1.25 }, { kcal: 50.4, proteinG: 2 }]), { kcal: 150, proteinG: 3.3 });
  const t = totalsForItems([
    { nutrients: { kcal: 200 }, range: { kcalLow: 150, kcalHigh: 260 } },
    { nutrients: { kcal: 100 } },
  ]);
  assert.deepEqual(t.totalsRange, { kcalLow: 250, kcalHigh: 360 });
  assert.equal(t.totals.kcal, 300);
});

test("recomputeMeal: server totals, weighed items collapse range, isEstimate from items", () => {
  const meal = recomputeMeal({
    items: [
      { id: "a", name: "x", grams: 100, weightSource: "scale", nutrients: { kcal: 100 }, range: { kcalLow: 50, kcalHigh: 200 } },
      { id: "b", name: "y", grams: 50, weightSource: "estimated", nutrients: { kcal: 80 }, range: { kcalLow: 60, kcalHigh: 110 } },
    ],
  });
  assert.deepEqual(meal.items[0].range, { kcalLow: 100, kcalHigh: 100 });
  assert.deepEqual(meal.totalsRange, { kcalLow: 160, kcalHigh: 210 });
  assert.equal(meal.totals.kcal, 180);
  assert.equal(meal.isEstimate, true);
});

test("recipePer100g uses cooked weight", () => {
  const per = recipePer100g({ items: [{ grams: 100, nutrients: { kcal: 300 } }, { grams: 100, nutrients: { kcal: 100 } }], totalCookedWeightG: 400 });
  assert.equal(per.kcal, 100);
});

test("USDA nutrient normalisation maps FDC ids and handles detail format + kJ energy", () => {
  const search = normalizeNutrients([
    { nutrientId: 1008, value: 130, unitName: "KCAL" },
    { nutrientId: 1062, value: 544, unitName: "kJ" },
    { nutrientId: 1003, value: 2.69, unitName: "G" },
    { nutrientId: 1005, value: 28.2, unitName: "G" },
    { nutrientId: 1004, value: 0.28, unitName: "G" },
    { nutrientId: 1079, value: 0.4, unitName: "G" },
    { nutrientId: 2000, value: 0.05, unitName: "G" },
    { nutrientId: 1093, value: 1, unitName: "MG" },
  ]);
  assert.deepEqual(search, { kcal: 130, proteinG: 2.7, carbsG: 28.2, fatG: 0.3, fiberG: 0.4, sugarG: 0.1, sodiumMg: 1 });
  const detail = normalizeNutrients([
    { nutrient: { id: 2047, unitName: "kcal" }, amount: 120 },
    { nutrient: { id: 1003, unitName: "g" }, amount: 20 },
  ]);
  assert.equal(detail.kcal, 120, "falls back to Atwater energy when 1008 missing");
  assert.equal(detail.proteinG, 20);
});

test("Open Food Facts mapping converts sodium g → mg", () => {
  const f = mapOffProduct({ code: "3017620422003", product_name: "Spread", brands: "Brand, Other", nutriments: { "energy-kcal_100g": 539, proteins_100g: 6.3, sodium_100g: 0.0428 } });
  assert.equal(f.foodRef.db, "off");
  assert.equal(f.nutrientsPer100g.sodiumMg, 43);
  assert.equal(f.brand, "Brand");
  assert.equal(f.gtin, "03017620422003");
});
