/**
 * Open Food Facts barcode fallback (used when FDC has no branded match).
 *
 * LICENCE: Open Food Facts data is available under the Open Database License (ODbL 1.0); product
 * images are CC BY-SA. Attribution ("Data from Open Food Facts, ODbL") must be shown in the app
 * wherever OFF-sourced foods are displayed, and any public redistribution of a derived database
 * must be shared alike under ODbL. We only cache individual lookups for 30 days.
 */
import { gtinKey, normalizeGtin } from "../lib/keys.js";
import { roundNutrients } from "./nutrition.js";

export const OFF_BASE = "https://world.openfoodfacts.org/api/v2/product";
export const OFF_ATTRIBUTION = "Data from Open Food Facts (ODbL)";

/**
 * Map an OFF product to our food shape.
 * @param {any} product
 */
export function mapOffProduct(product) {
  const n = product?.nutriments ?? {};
  let kcal = n["energy-kcal_100g"];
  if (kcal === undefined && typeof n["energy_100g"] === "number") kcal = n["energy_100g"] / 4.184; // kJ → kcal
  const per100 = {
    kcal,
    proteinG: n.proteins_100g,
    carbsG: n.carbohydrates_100g,
    fatG: n.fat_100g,
    fiberG: n.fiber_100g,
    sugarG: n.sugars_100g,
    sodiumMg: typeof n.sodium_100g === "number" ? n.sodium_100g * 1000 : (typeof n.salt_100g === "number" ? (n.salt_100g / 2.5) * 1000 : undefined),
  };
  const gtin = normalizeGtin(product.code);
  const out = {
    foodRef: { db: "off", id: gtin },
    name: product.product_name || "Unknown product",
    nutrientsPer100g: roundNutrients(per100),
    gtin,
    attribution: OFF_ATTRIBUTION,
  };
  if (product.brands) out.brand = String(product.brands).split(",")[0].trim();
  if (typeof product.serving_quantity === "number" || /^\d+(\.\d+)?$/.test(String(product.serving_quantity ?? ""))) {
    out.servingG = Number(product.serving_quantity);
  }
  return out;
}

/**
 * @param {{ fetch?: typeof fetch, catalog?: import("../lib/db.js").CatalogStore, userAgent?: string }} opts
 */
export function createOpenFoodFactsClient({ fetch: fetchImpl = globalThis.fetch, catalog, userAgent = "HealthApp/1.0 (backend)" } = {}) {
  return {
    /** @param {string} code @returns {Promise<any|undefined>} */
    async lookup(code) {
      const gtin = normalizeGtin(code);
      const cached = await catalog?.get(gtinKey(gtin));
      if (cached?.off) return cached.off;
      const fields = "code,product_name,brands,nutriments,serving_quantity";
      const res = await fetchImpl(`${OFF_BASE}/${gtin.replace(/^0+(?=\d{8})/, "")}.json?fields=${fields}`, {
        headers: { "user-agent": userAgent, accept: "application/json" },
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) return undefined;
      const data = await res.json();
      if (data?.status !== 1 || !data.product) return undefined;
      const food = mapOffProduct({ ...data.product, code: data.product.code ?? gtin });
      if (food.nutrientsPer100g.kcal === undefined) return undefined;
      await catalog?.put(gtinKey(gtin), { off: food }, 30);
      return food;
    },
  };
}
