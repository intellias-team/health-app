/**
 * Voice logging (POST /v1/ai/voice-parse): transcript → (quantity, unit, food) items via structured
 * output → grams via USDA household portions (fallback: built-in table) → nutrients computed
 * server-side from the database.
 */
import { computeItemNutrition, totalsForItems } from "../nutrition.js";
import { structuredCall } from "./claude.js";

export const VOICE_SYSTEM_PROMPT = `You convert a spoken food log into structured items for a nutrition app.

Extract each food the person says they ate or drank, with the quantity and unit exactly as spoken (e.g. 2 + "egg", 1 + "cup", 150 + "g", 1 + "slice"). If no quantity is given, use 1 and unit "serving". Do not estimate calories or nutrients. Do not invent foods that were not mentioned. Write a generic USDA FoodData Central search phrase for each food.`;

export const VOICE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["items"],
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["quantity", "unit", "food", "usdaSearchQuery", "preparation"],
        properties: {
          quantity: { type: "number" },
          unit: { type: "string", description: "Unit as spoken: g, kg, oz, lb, ml, l, cup, tbsp, tsp, slice, piece, egg, serving, …" },
          food: { type: "string" },
          usdaSearchQuery: { type: "string" },
          preparation: { type: "string", description: "e.g. scrambled, boiled, raw, or empty" },
        },
      },
    },
  },
};

/** Mass/volume units with fixed gram factors (volume assumes ~water density). */
const FIXED_UNITS = {
  g: 1, gram: 1, grams: 1, gr: 1,
  kg: 1000, kilogram: 1000, kilograms: 1000,
  oz: 28.35, ounce: 28.35, ounces: 28.35,
  lb: 453.6, lbs: 453.6, pound: 453.6, pounds: 453.6,
  ml: 1, milliliter: 1, milliliters: 1, millilitre: 1, millilitres: 1,
  l: 1000, liter: 1000, liters: 1000, litre: 1000, litres: 1000,
};
const EXACT_MASS_UNITS = new Set(["g", "gram", "grams", "gr", "kg", "kilogram", "kilograms", "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds"]);

/**
 * Built-in household portion table (grams per unit), used when USDA has no matching portion.
 * Keys are `"<unit>|<food keyword>"` or `"<unit>|*"` for a generic default.
 */
export const HOUSEHOLD_GRAMS = Object.freeze({
  "egg|*": 50, "piece|egg": 50, "serving|egg": 50, "large|egg": 50,
  "slice|bread": 30, "slice|toast": 30, "slice|cheese": 20, "slice|ham": 15, "slice|pizza": 107, "slice|*": 30,
  "cup|cottage cheese": 226, "cup|milk": 244, "cup|yogurt": 245, "cup|rice": 158, "cup|oats": 81, "cup|oatmeal": 234,
  "cup|pasta": 140, "cup|berries": 148, "cup|blueberries": 148, "cup|spinach": 30, "cup|juice": 248, "cup|coffee": 237, "cup|*": 240,
  "tbsp|oil": 13.5, "tbsp|olive oil": 13.5, "tbsp|butter": 14, "tbsp|peanut butter": 16, "tbsp|honey": 21, "tbsp|sugar": 12.5, "tbsp|*": 15,
  "tsp|sugar": 4.2, "tsp|oil": 4.5, "tsp|*": 5,
  "piece|banana": 118, "piece|apple": 182, "piece|orange": 131, "piece|chicken breast": 174, "piece|cookie": 15, "piece|*": 100,
  "medium|banana": 118, "medium|apple": 182, "banana|*": 118, "apple|*": 182,
  "handful|nuts": 28, "handful|almonds": 28, "handful|*": 30,
  "scoop|protein": 30, "scoop|*": 30,
  "can|*": 355, "bottle|*": 500, "glass|*": 240, "bowl|*": 300, "plate|*": 350,
  "serving|*": 100,
});

const UNIT_ALIASES = {
  cups: "cup", tablespoon: "tbsp", tablespoons: "tbsp", tbs: "tbsp", tbsps: "tbsp", teaspoon: "tsp", teaspoons: "tsp", tsps: "tsp",
  slices: "slice", pieces: "piece", pc: "piece", pcs: "piece", eggs: "egg", servings: "serving", portion: "serving",
  handfuls: "handful", scoops: "scoop", cans: "can", bottles: "bottle", glasses: "glass", bowls: "bowl", "": "serving", whole: "piece",
};

/** @param {string} unit */
export function normalizeUnit(unit) {
  const u = String(unit ?? "").toLowerCase().trim().replace(/\.$/, "");
  return UNIT_ALIASES[u] ?? u;
}

/**
 * Convert (quantity, unit, food) to grams.
 * @param {{ quantity: number, unit: string, food: string }} item
 * @param {{ label: string, gramsPerUnit: number }[]} [portions] USDA household portions
 * @returns {{ grams: number, method: "mass"|"volume"|"usda_portion"|"household_table", exact: boolean }}
 */
export function toGrams({ quantity, unit, food }, portions = []) {
  const q = Number(quantity) > 0 ? Number(quantity) : 1;
  const u = normalizeUnit(unit);
  if (FIXED_UNITS[u]) {
    return { grams: Math.round(q * FIXED_UNITS[u] * 10) / 10, method: EXACT_MASS_UNITS.has(u) ? "mass" : "volume", exact: EXACT_MASS_UNITS.has(u) };
  }
  const portion = portions.find((p) => p.label.split(/[^a-z]+/i).some((w) => normalizeUnit(w) === u));
  if (portion) return { grams: Math.round(q * portion.gramsPerUnit * 10) / 10, method: "usda_portion", exact: false };

  const f = String(food ?? "").toLowerCase();
  const candidates = Object.keys(HOUSEHOLD_GRAMS)
    .filter((k) => k.startsWith(`${u}|`) && k !== `${u}|*`)
    .filter((k) => f.includes(k.split("|")[1]))
    .sort((a, b) => b.length - a.length);
  const key = candidates[0] ?? (HOUSEHOLD_GRAMS[`${u}|*`] !== undefined ? `${u}|*` : `serving|*`);
  return { grams: Math.round(q * HOUSEHOLD_GRAMS[key] * 10) / 10, method: "household_table", exact: false };
}

/**
 * @param {{
 *   input: { transcript: string, mealCategory?: string },
 *   deps: { claude: any, usda: import("../usda.js").UsdaClient },
 * }} p
 */
export async function parseVoiceLog({ input, deps }) {
  const parsed = await structuredCall(deps.claude, {
    system: VOICE_SYSTEM_PROMPT,
    schema: VOICE_SCHEMA,
    effort: "low",
    content: [{ type: "text", text: `Transcript: """${input.transcript.slice(0, 2000)}"""` }],
  });

  const items = [];
  for (const [i, raw] of (parsed.items ?? []).slice(0, 20).entries()) {
    const food = String(raw.food ?? "").slice(0, 200);
    const query = [raw.usdaSearchQuery || food, raw.preparation].filter(Boolean).join(" ");
    const hits = await deps.usda.search(query, { limit: 3, genericOnly: true });
    const best = hits[0];
    const detail = best ? await deps.usda.getFood(best.foodRef.id).catch(() => undefined) : undefined;
    const conv = toGrams({ quantity: raw.quantity, unit: raw.unit, food }, detail?.portions ?? []);
    const spread = conv.exact ? 0 : conv.method === "usda_portion" ? 0.1 : 0.2;
    const portion = {
      grams: conv.grams,
      gramsLow: Math.round(conv.grams * (1 - spread)),
      gramsHigh: Math.round(conv.grams * (1 + spread)),
    };
    const base = {
      id: `v${i + 1}`,
      name: best?.name ?? food,
      spoken: { quantity: raw.quantity, unit: raw.unit, food },
      ...portion,
      weightSource: conv.exact ? "user" : "estimated",
      conversion: conv.method,
      confidence: null,
    };
    if (!best) {
      items.push({ ...base, foodRef: { db: "ai" }, nutrients: {}, range: { kcalLow: 0, kcalHigh: 0 }, alternatives: [] });
      continue;
    }
    const per100 = detail?.nutrientsPer100g ?? best.nutrientsPer100g;
    items.push({
      ...base,
      foodRef: best.foodRef,
      ...computeItemNutrition(per100, portion),
      alternatives: hits.slice(1).map((h) => ({ name: h.name, foodRef: h.foodRef })),
    });
  }
  const { totals, totalsRange } = totalsForItems(items);
  return { items, totals, totalsRange, isEstimate: items.some((i) => i.weightSource !== "user") };
}
