/**
 * USDA FoodData Central client (https://fdc.nal.usda.gov/api-guide) with a DynamoDB cache in
 * `HealthAppFoodCatalog` (schema §2.3).
 *
 * FDC data is public domain (CC0). Values are normalised to our `nutrientsPer100g` shape:
 *   1008 kcal · 1003 protein · 1005 carbs · 1004 fat · 1079 fiber · 2000 sugars · 1093 sodium
 * (Foundation foods sometimes omit 1008; Atwater energies 2047/2048 are used as fallbacks.)
 */
import { ApiError } from "../lib/http.js";
import { fdcKey, gtinKey, normalizeGtin, normalizeQuery, searchKey } from "../lib/keys.js";
import { roundNutrients } from "./nutrition.js";

export const FDC_BASE = "https://api.nal.usda.gov/fdc/v1";

/** FDC nutrient id → our key. Order matters for kcal fallbacks. */
export const NUTRIENT_IDS = Object.freeze({
  1008: "kcal",
  1003: "proteinG",
  1005: "carbsG",
  1004: "fatG",
  1079: "fiberG",
  2000: "sugarG",
  1093: "sodiumMg",
});
const KCAL_FALLBACK_IDS = [2047, 2048];
/** Legacy nutrient "numbers" used by some FDC payloads. */
const NUTRIENT_NUMBERS = { "208": 1008, "203": 1003, "205": 1005, "204": 1004, "291": 1079, "269": 2000, "307": 1093 };

const GENERIC_TYPES = ["Foundation", "SR Legacy", "Survey (FNDDS)"];
const CACHE_DAYS = { food: 30, gtin: 30, search: 1 };

/**
 * Normalise FDC `foodNutrients` (search or detail format) to per-100 g nutrients.
 * @param {any[]} foodNutrients
 * @returns {import("./nutrition.js").Nutrients}
 */
export function normalizeNutrients(foodNutrients = []) {
  const byId = new Map();
  for (const fn of foodNutrients) {
    let id = fn.nutrientId ?? fn.nutrient?.id;
    if (id === undefined && (fn.nutrientNumber ?? fn.nutrient?.number)) id = NUTRIENT_NUMBERS[String(fn.nutrientNumber ?? fn.nutrient?.number)];
    const unit = String(fn.unitName ?? fn.nutrient?.unitName ?? "").toUpperCase();
    const value = fn.value ?? fn.amount;
    if (id === undefined || typeof value !== "number") continue;
    if ((id === 1008 || KCAL_FALLBACK_IDS.includes(id)) && unit && unit !== "KCAL") continue;
    byId.set(Number(id), { value, unit });
  }
  const out = {};
  for (const [id, key] of Object.entries(NUTRIENT_IDS)) {
    const hit = byId.get(Number(id));
    if (!hit) continue;
    let value = hit.value;
    if (key === "sodiumMg" && hit.unit === "G") value *= 1000;
    out[key] = value;
  }
  if (out.kcal === undefined) {
    for (const id of KCAL_FALLBACK_IDS) {
      if (byId.has(id)) {
        out.kcal = byId.get(id).value;
        break;
      }
    }
  }
  return roundNutrients(out);
}

/** Household portions from an FDC detail payload. */
export function normalizePortions(food) {
  const portions = [];
  for (const p of food.foodPortions ?? []) {
    if (typeof p.gramWeight !== "number" || p.gramWeight <= 0) continue;
    const amount = typeof p.amount === "number" && p.amount > 0 ? p.amount : 1;
    const unitName = p.measureUnit?.name && p.measureUnit.name !== "undetermined" ? p.measureUnit.name : "";
    const label = [unitName, p.modifier, p.portionDescription].filter(Boolean).join(" ").trim() || "portion";
    portions.push({ label: label.toLowerCase(), gramsPerUnit: Math.round((p.gramWeight / amount) * 10) / 10 });
  }
  if (typeof food.servingSize === "number" && /^(g|grm)$/i.test(food.servingSizeUnit ?? "")) {
    portions.push({ label: (food.householdServingFullText || "serving").toLowerCase(), gramsPerUnit: food.servingSize });
  }
  return portions;
}

/** @param {any} food FDC search hit or detail */
function toFood(food) {
  const out = {
    foodRef: { db: "usda", id: String(food.fdcId) },
    name: titleCase(food.description ?? ""),
    dataType: food.dataType,
    nutrientsPer100g: normalizeNutrients(food.foodNutrients),
  };
  const brand = food.brandName || food.brandOwner;
  if (brand) out.brand = brand;
  if (typeof food.servingSize === "number" && /^(g|grm)$/i.test(food.servingSizeUnit ?? "")) out.servingG = food.servingSize;
  if (food.gtinUpc) out.gtin = normalizeGtinSafe(food.gtinUpc);
  return out;
}

function normalizeGtinSafe(code) {
  try {
    return normalizeGtin(code);
  } catch {
    return undefined;
  }
}

function titleCase(s) {
  const lower = s.toLowerCase();
  return lower.charAt(0).toUpperCase() + lower.slice(1);
}

/**
 * @param {{
 *   getApiKey: () => Promise<string>,
 *   fetch?: typeof fetch,
 *   catalog?: import("../lib/db.js").CatalogStore,
 *   baseUrl?: string,
 * }} opts
 */
export function createUsdaClient({ getApiKey, fetch: fetchImpl = globalThis.fetch, catalog, baseUrl = FDC_BASE }) {
  async function call(path, init = {}) {
    const key = await getApiKey();
    const url = `${baseUrl}${path}${path.includes("?") ? "&" : "?"}api_key=${encodeURIComponent(key)}`;
    const res = await fetchImpl(url, {
      ...init,
      headers: { accept: "application/json", ...(init.body ? { "content-type": "application/json" } : {}), ...(init.headers ?? {}) },
      signal: init.signal ?? AbortSignal.timeout(8000),
    });
    if (res.status === 404) return undefined;
    if (!res.ok) throw new ApiError("UPSTREAM_ERROR", `FoodData Central error ${res.status}`);
    return res.json();
  }

  /**
   * Search foods. Generic (non-branded) foods are preferred for photo/voice matching.
   * @param {string} query
   * @param {{ limit?: number, genericOnly?: boolean }} [opts]
   * @returns {Promise<any[]>} FoodSummary[]
   */
  async function search(query, { limit = 25, genericOnly = false } = {}) {
    const q = normalizeQuery(query);
    if (!q) return [];
    const cacheKey = searchKey(`${genericOnly ? "g:" : ""}${q}`);
    const cached = await catalog?.get(cacheKey);
    if (cached?.foods) return cached.foods.slice(0, limit);
    const body = { query: q, pageSize: 25, ...(genericOnly ? { dataType: GENERIC_TYPES } : {}) };
    const data = await call("/foods/search", { method: "POST", body: JSON.stringify(body) });
    const foods = (data?.foods ?? []).map(toFood).filter((f) => f.nutrientsPer100g.kcal !== undefined);
    await catalog?.put(cacheKey, { foods }, CACHE_DAYS.search);
    return foods.slice(0, limit);
  }

  /**
   * Food detail with portions (cached 30 days).
   * @param {string|number} fdcId
   */
  async function getFood(fdcId) {
    const id = String(fdcId);
    if (!/^\d{1,10}$/.test(id)) throw new ApiError("VALIDATION_ERROR", "Invalid FDC id");
    const cached = await catalog?.get(fdcKey(id));
    if (cached?.food) return cached.food;
    const data = await call(`/food/${id}`);
    if (!data) return undefined;
    const food = { ...toFood(data), portions: normalizePortions(data) };
    await catalog?.put(fdcKey(id), { food, dataType: data.dataType }, CACHE_DAYS.food);
    return food;
  }

  /**
   * Branded food lookup by barcode via `gtinUpc`.
   * @param {string} code UPC/EAN/GTIN
   */
  async function lookupGtin(code) {
    const gtin = normalizeGtin(code);
    const cached = await catalog?.get(gtinKey(gtin));
    if (cached?.fdcId) return getFood(cached.fdcId);
    const data = await call("/foods/search", {
      method: "POST",
      body: JSON.stringify({ query: gtin.replace(/^0+/, ""), dataType: ["Branded"], pageSize: 10 }),
    });
    const hit = (data?.foods ?? []).find((f) => f.gtinUpc && normalizeGtinSafe(f.gtinUpc) === gtin);
    if (!hit) return undefined;
    await catalog?.put(gtinKey(gtin), { fdcId: String(hit.fdcId) }, CACHE_DAYS.gtin);
    return getFood(hit.fdcId);
  }

  return { search, getFood, lookupGtin };
}

/** @typedef {ReturnType<typeof createUsdaClient>} UsdaClient */
