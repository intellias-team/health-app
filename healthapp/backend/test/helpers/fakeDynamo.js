/**
 * In-memory fake of the DocumentClient adapter used by `src/lib/db.js`
 * (get/put/update/delete/query/scan/batchWrite). Implements the expression subset the
 * repository uses: comparisons, BETWEEN, begins_with, attribute_(not_)exists, AND/OR/NOT,
 * parentheses; update SET (incl. if_not_exists) / ADD / REMOVE.
 */

const INDEX_KEYS = { GSI1: ["GSI1PK", "GSI1SK"], GSI2: ["GSI2PK", "GSI2SK"] };

function conditionalFailure() {
  const err = new Error("The conditional request failed");
  err.name = "ConditionalCheckFailedException";
  return err;
}

function tokenize(expr) {
  const re = /\s*(<>|<=|>=|=|<|>|\(|\)|,|[#:]?[A-Za-z_][A-Za-z0-9_]*)/y;
  const out = [];
  let m;
  re.lastIndex = 0;
  while (re.lastIndex < expr.length && (m = re.exec(expr))) out.push(m[1]);
  if (re.lastIndex < expr.trim().length) throw new Error(`fakeDynamo: cannot tokenize '${expr}'`);
  return out;
}

/** Evaluate a condition expression against an item (undefined item = absent). */
export function evaluate(expr, item, names = {}, values = {}) {
  const tokens = tokenize(expr);
  let i = 0;
  const peek = () => tokens[i];
  const next = () => tokens[i++];
  const attr = (tok) => (tok.startsWith("#") ? names[tok] : tok);
  const operand = (tok) => (tok.startsWith(":") ? values[tok] : item?.[attr(tok)]);

  function primary() {
    const t = next();
    if (t === "(") {
      const v = orExpr();
      next(); // )
      return v;
    }
    if (t.toUpperCase() === "NOT") return !primary();
    if (["attribute_exists", "attribute_not_exists", "begins_with"].includes(t)) {
      next(); // (
      const a = next();
      let b;
      if (peek() === ",") {
        next();
        b = next();
      }
      next(); // )
      const val = item?.[attr(a)];
      if (t === "attribute_exists") return val !== undefined;
      if (t === "attribute_not_exists") return val === undefined;
      return typeof val === "string" && val.startsWith(operand(b));
    }
    const left = operand(t);
    const op = next();
    if (op.toUpperCase() === "BETWEEN") {
      const lo = operand(next());
      next(); // AND
      const hi = operand(next());
      return left !== undefined && left >= lo && left <= hi;
    }
    const right = operand(next());
    if (left === undefined) return op === "<>";
    switch (op) {
      case "=": return left === right;
      case "<>": return left !== right;
      case "<": return left < right;
      case "<=": return left <= right;
      case ">": return left > right;
      case ">=": return left >= right;
      default: throw new Error(`fakeDynamo: operator ${op}`);
    }
  }
  function andExpr() {
    let v = primary();
    while (peek()?.toUpperCase() === "AND") {
      next();
      const r = primary();
      v = v && r;
    }
    return v;
  }
  function orExpr() {
    let v = andExpr();
    while (peek()?.toUpperCase() === "OR") {
      next();
      const r = andExpr();
      v = v || r;
    }
    return v;
  }
  return orExpr();
}

function applyUpdate(item, expr, names = {}, values = {}) {
  const attr = (tok) => (tok.startsWith("#") ? names[tok] : tok);
  const parts = expr.split(/\b(SET|ADD|REMOVE)\b/).map((s) => s.trim()).filter(Boolean);
  for (let p = 0; p < parts.length; p += 2) {
    const kw = parts[p];
    const clauses = parts[p + 1].split(/,(?![^(]*\))/).map((s) => s.trim());
    for (const c of clauses) {
      if (kw === "SET") {
        const [lhs, rhs] = c.split("=").map((s) => s.trim());
        const ine = /^if_not_exists\(\s*([#\w]+)\s*,\s*(:\w+)\s*\)$/.exec(rhs);
        item[attr(lhs)] = ine ? item[attr(ine[1])] ?? values[ine[2]] : values[rhs];
      } else if (kw === "ADD") {
        const [a, v] = c.split(/\s+/);
        item[attr(a)] = (item[attr(a)] ?? 0) + values[v];
      } else if (kw === "REMOVE") {
        delete item[attr(c)];
      }
    }
  }
}

/** @returns {import("../../src/lib/db.js").DocClient & { tables: Map<string, Map<string, any>>, calls: any[] }} */
export function createFakeDocClient() {
  const tables = new Map();
  const calls = [];
  const table = (name) => {
    if (!tables.has(name)) tables.set(name, new Map());
    return tables.get(name);
  };
  const k = (key) => `${key.PK}\u0000${key.SK}`;
  const clone = (x) => (x === undefined ? undefined : structuredClone(x));

  function queryOrScan(p, isQuery) {
    const [ipk, isk] = p.IndexName ? INDEX_KEYS[p.IndexName] : ["PK", "SK"];
    let items = [...table(p.TableName).values()].filter((it) => it[ipk] !== undefined);
    if (isQuery) items = items.filter((it) => evaluate(p.KeyConditionExpression, it, p.ExpressionAttributeNames, p.ExpressionAttributeValues));
    items.sort((a, b) => (a[ipk] === b[ipk] ? (a[isk] < b[isk] ? -1 : a[isk] > b[isk] ? 1 : k(a) < k(b) ? -1 : 1) : a[ipk] < b[ipk] ? -1 : 1));
    if (p.ScanIndexForward === false) items.reverse();
    if (p.ExclusiveStartKey) {
      const idx = items.findIndex((it) => k(it) === k(p.ExclusiveStartKey));
      items = items.slice(idx + 1);
    }
    let last;
    if (p.Limit && items.length > p.Limit) {
      items = items.slice(0, p.Limit);
      const l = items[items.length - 1];
      last = { PK: l.PK, SK: l.SK };
    }
    if (p.FilterExpression) items = items.filter((it) => evaluate(p.FilterExpression, it, p.ExpressionAttributeNames, p.ExpressionAttributeValues));
    return { Items: items.map(clone), LastEvaluatedKey: last };
  }

  return {
    tables,
    calls,
    async get(p) {
      calls.push(["get", p]);
      return { Item: clone(table(p.TableName).get(k(p.Key))) };
    },
    async put(p) {
      calls.push(["put", p]);
      const t = table(p.TableName);
      const existing = t.get(k(p.Item));
      if (p.ConditionExpression && !evaluate(p.ConditionExpression, existing, p.ExpressionAttributeNames, p.ExpressionAttributeValues)) throw conditionalFailure();
      t.set(k(p.Item), clone(p.Item));
      return {};
    },
    async update(p) {
      calls.push(["update", p]);
      const t = table(p.TableName);
      const existing = t.get(k(p.Key));
      if (p.ConditionExpression && !evaluate(p.ConditionExpression, existing, p.ExpressionAttributeNames, p.ExpressionAttributeValues)) throw conditionalFailure();
      const item = clone(existing) ?? { ...p.Key };
      applyUpdate(item, p.UpdateExpression, p.ExpressionAttributeNames, p.ExpressionAttributeValues);
      t.set(k(p.Key), item);
      return { Attributes: clone(item) };
    },
    async delete(p) {
      calls.push(["delete", p]);
      const t = table(p.TableName);
      const existing = t.get(k(p.Key));
      if (p.ConditionExpression && !evaluate(p.ConditionExpression, existing, p.ExpressionAttributeNames, p.ExpressionAttributeValues)) throw conditionalFailure();
      t.delete(k(p.Key));
      return { Attributes: p.ReturnValues === "ALL_OLD" ? clone(existing) : undefined };
    },
    async query(p) {
      calls.push(["query", p]);
      return queryOrScan(p, true);
    },
    async scan(p) {
      calls.push(["scan", p]);
      return queryOrScan(p, false);
    },
    async batchWrite(p) {
      calls.push(["batchWrite", p]);
      for (const [name, reqs] of Object.entries(p.RequestItems)) {
        if (reqs.length > 25) throw new Error("batchWrite > 25");
        for (const r of reqs) {
          if (r.DeleteRequest) table(name).delete(k(r.DeleteRequest.Key));
          if (r.PutRequest) table(name).set(k(r.PutRequest.Item), clone(r.PutRequest.Item));
        }
      }
      return { UnprocessedItems: {} };
    },
  };
}
