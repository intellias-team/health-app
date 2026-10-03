/**
 * nutritionFn — /v1/meals*, /v1/foods*, /v1/recipes*
 */
import { ApiError, createRouter, json, noContent, requireQuery } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { customFoodKey, mealKey, normalizeQuery, recipeKey, skPrefix, skRange } from "../lib/keys.js";
import { toPublic } from "../lib/db.js";
import { customFoodSchema, mealSchema, recipeSchema } from "../lib/schemas.js";
import { assertOwnPhotoKey, MEAL_RETENTION_TAG } from "../lib/s3.js";
import { daysBetween, isDate } from "../lib/dates.js";
import { recipePer100g, recomputeMeal } from "../services/nutrition.js";
import * as d from "../lib/deps.js";

const MAX_RANGE_DAYS = 92;

/** Validate a `from`/`to` date window. */
export function dateWindow(req, maxDays = MAX_RANGE_DAYS) {
  const from = requireQuery(req, "from");
  const to = requireQuery(req, "to");
  if (!isDate(from) || !isDate(to) || from > to) throw new ApiError("VALIDATION_ERROR", "from/to must be dates with from <= to");
  if (daysBetween(from, to) > maxDays) throw new ApiError("VALIDATION_ERROR", `Date range too long (max ${maxDays} days)`);
  return { from, to };
}

/**
 * Validate + recompute a meal for storage (shared with sync push).
 * @param {string} sub @param {any} raw
 */
export function prepareMeal(sub, raw) {
  const meal = recomputeMeal(validate(mealSchema, raw));
  if (meal.photoKey) assertOwnPhotoKey(sub, meal.photoKey);
  return meal;
}

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   media: Pick<import("../lib/s3.js").MediaStore, "setTags"|"deleteObject">,
 *   usda: import("../services/usda.js").UsdaClient,
 *   off?: { lookup: (gtin: string) => Promise<any> },
 *   logger?: any,
 * }} deps
 */
export function createHandler(deps) {
  const { repo, media, usda, off } = deps;
  const logger = deps.logger ?? d.logger;

  async function findMealById(sub, id, date) {
    if (date) return repo.get(mealKey(sub, date, id), { includeDeleted: true });
    const all = await repo.queryPrefix(skPrefix(sub, "MEAL"), { includeDeleted: true, descending: true });
    return all.find((m) => m.id === id);
  }

  return createRouter([
    {
      method: "GET", path: "/v1/meals",
      handler: async (req) => {
        const { from, to } = dateWindow(req);
        const meals = await repo.queryRange(skRange(req.sub, "MEAL", from, to));
        return json(200, { meals: meals.map(toPublic) });
      },
    },
    {
      method: "PUT", path: "/v1/meals/{id}",
      handler: async ({ sub, params, body, headers }) => {
        const raw = { ...(body ?? {}), id: params.id };
        const meal = prepareMeal(sub, raw);
        if (headers["idempotency-key"] && headers["idempotency-key"].toLowerCase() !== meal.id) {
          throw new ApiError("VALIDATION_ERROR", "Idempotency-Key must equal the meal id");
        }
        const expectedVersion = body?.version === undefined ? undefined : validate(v.number({ int: true, min: 0 }), body.version, "version");
        // A meal moved to another date: tombstone the old key so other devices drop it.
        if (body?.previousDate && isDate(body.previousDate) && body.previousDate !== meal.date) {
          await repo.tombstone(sub, mealKey(sub, body.previousDate, meal.id), "meal", meal.id).catch((err) => {
            if (err?.code !== "CONFLICT") throw err;
          });
        }
        const saved = await repo.putVersioned(sub, mealKey(sub, meal.date, meal.id), "meal", meal.id, meal, { expectedVersion });
        if (meal.photoKey && meal.photoPinned !== undefined) {
          await media.setTags(meal.photoKey, meal.photoPinned ? { pinned: "true" } : Object.fromEntries([MEAL_RETENTION_TAG.split("=")]))
            .catch((err) => logger.warn("photo tag update failed", { err }));
        }
        return json(200, { meal: toPublic(saved) });
      },
    },
    {
      method: "DELETE", path: "/v1/meals/{id}",
      handler: async ({ sub, params, query }) => {
        if (query.date && !isDate(query.date)) throw new ApiError("VALIDATION_ERROR", "date must be yyyy-mm-dd");
        const existing = await findMealById(sub, validate(v.uuid(), params.id, "id"), query.date);
        if (!existing) throw new ApiError("NOT_FOUND", "Meal not found");
        if (!existing.deleted) {
          await repo.tombstone(sub, { PK: existing.PK, SK: existing.SK }, "meal", existing.id);
          if (existing.photoKey) await media.deleteObject(existing.photoKey).catch((err) => logger.warn("photo delete failed", { err }));
        }
        return noContent();
      },
    },
    {
      method: "GET", path: "/v1/foods/search",
      handler: async ({ sub, query }) => {
        const q = validate(v.string({ min: 1, max: 100 }), query.q, "q");
        const limit = query.limit ? validate(v.number({ int: true, min: 1, max: 25 }), query.limit, "limit") : 25;
        const nq = normalizeQuery(q);
        const custom = (await repo.queryPrefix(skPrefix(sub, "FOOD")))
          .filter((f) => normalizeQuery(`${f.name} ${f.brand ?? ""}`).includes(nq))
          .slice(0, 5)
          .map((f) => ({ foodRef: { db: "custom", id: f.id }, name: f.name, brand: f.brand, servingG: f.servingG, nutrientsPer100g: f.nutrientsPer100g }));
        const usdaFoods = await usda.search(q, { limit });
        return json(200, { foods: [...custom, ...usdaFoods].slice(0, limit) });
      },
    },
    {
      method: "GET", path: "/v1/foods/barcode/{gtin}",
      handler: async ({ params }) => {
        let food = await usda.lookupGtin(params.gtin);
        if (!food && off) food = await off.lookup(params.gtin);
        if (!food) throw new ApiError("NOT_FOUND", "No food found for this barcode");
        return json(200, { food });
      },
    },
    {
      method: "PUT", path: "/v1/foods/custom/{id}",
      handler: async ({ sub, params, body }) => {
        const id = validate(v.id(), params.id, "id");
        const food = validate(customFoodSchema, body ?? {});
        const saved = await repo.putVersioned(sub, customFoodKey(sub, id), "customFood", id, food);
        return json(200, { food: { foodRef: { db: "custom", id }, ...toPublic(saved) } });
      },
    },
    {
      method: "GET", path: "/v1/foods/{db}/{id}",
      handler: async ({ sub, params }) => {
        let food;
        switch (params.db) {
          case "usda": food = await usda.getFood(params.id); break;
          case "off": food = off ? await off.lookup(params.id) : undefined; break;
          case "custom": {
            const item = await repo.get(customFoodKey(sub, validate(v.id(), params.id, "id")));
            if (item) food = { foodRef: { db: "custom", id: item.id }, ...toPublic(item), portions: [{ label: "serving", gramsPerUnit: item.servingG }] };
            break;
          }
          case "recipe": {
            const item = await repo.get(recipeKey(sub, validate(v.id(), params.id, "id")));
            if (item) {
              const weight = item.totalCookedWeightG || item.items.reduce((s, i) => s + (i.grams || 0), 0);
              food = { foodRef: { db: "recipe", id: item.id }, name: item.name, nutrientsPer100g: recipePer100g(item), portions: [{ label: "serving", gramsPerUnit: Math.round(weight / (item.servings || 1)) }] };
            }
            break;
          }
          default:
            throw new ApiError("VALIDATION_ERROR", "db must be usda, off, custom or recipe");
        }
        if (!food) throw new ApiError("NOT_FOUND", "Food not found");
        return json(200, { food });
      },
    },
    {
      method: "GET", path: "/v1/recipes",
      handler: async ({ sub }) => json(200, { recipes: (await repo.queryPrefix(skPrefix(sub, "RECIPE"))).map(toPublic) }),
    },
    {
      method: "GET", path: "/v1/recipes/{id}",
      handler: async ({ sub, params }) => {
        const r = await repo.get(recipeKey(sub, validate(v.id(), params.id, "id")));
        if (!r) throw new ApiError("NOT_FOUND", "Recipe not found");
        return json(200, { recipe: { ...toPublic(r), nutrientsPer100g: recipePer100g(r) } });
      },
    },
    {
      method: "PUT", path: "/v1/recipes/{id}",
      handler: async ({ sub, params, body }) => {
        const id = validate(v.id(), params.id, "id");
        const recipe = validate(recipeSchema, body ?? {});
        const expectedVersion = body?.version === undefined ? undefined : validate(v.number({ int: true, min: 0 }), body.version, "version");
        const saved = await repo.putVersioned(sub, recipeKey(sub, id), "recipe", id, recipe, { expectedVersion });
        return json(200, { recipe: toPublic(saved) });
      },
    },
    {
      method: "DELETE", path: "/v1/recipes/{id}",
      handler: async ({ sub, params }) => {
        const id = validate(v.id(), params.id, "id");
        const r = await repo.tombstone(sub, recipeKey(sub, id), "recipe", id);
        if (!r) throw new ApiError("NOT_FOUND", "Recipe not found");
        return noContent();
      },
    },
  ], { logger });
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  media: await d.mediaStore(),
  usda: await d.usdaClient(),
  off: await d.offClient(),
}));
