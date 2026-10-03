/**
 * Read-side helpers over the repository, shared by day summary, trends, coach tools and
 * notifications. Every function is scoped to one `sub`.
 */
import { addDays } from "../lib/dates.js";
import { goalsKey, profileKey, skRange } from "../lib/keys.js";
import { toPublic } from "../lib/db.js";
import { mergeDayItems } from "./merge.js";

/**
 * @param {import("../lib/db.js").Repository} repo
 * @param {string} sub
 */
export function createUserData(repo, sub) {
  return {
    async profile() {
      return toPublic(await repo.get(profileKey(sub))) ?? {};
    },
    async goals() {
      return toPublic(await repo.get(goalsKey(sub))) ?? {};
    },
    /** Meals with `date` in [from, to]. */
    async meals(from, to) {
      return (await repo.queryRange(skRange(sub, "MEAL", from, to))).map(toPublic);
    },
    /** Merged daily metrics in [from, to]. */
    async daily(from, to, preferences) {
      const items = await repo.queryRange(skRange(sub, "DAY", from, to));
      return mergeDayItems(items, preferences);
    },
    /**
     * Body measurements. SKs hold UTC timestamps, so the window is widened by a day on each side;
     * callers that need exact local dates filter on `measuredAt`.
     */
    async body(from, to) {
      return (await repo.queryRange(skRange(sub, "BODY", addDays(from, -1), addDays(to, 1)))).map(toPublic);
    },
    /** Workouts (same widening as body). */
    async workouts(from, to) {
      return (await repo.queryRange(skRange(sub, "WORKOUT", addDays(from, -1), addDays(to, 1)))).map(toPublic);
    },
    async cycle(from, to) {
      return (await repo.queryRange(skRange(sub, "CYCLE", from, to))).map(toPublic);
    },
    async notes(from, to) {
      return (await repo.queryRange(skRange(sub, "NOTE", from, to))).map(toPublic);
    },
  };
}

/** @typedef {ReturnType<typeof createUserData>} UserData */
