--- Chainable query builder. Terminal methods (all/first/count/update/delete)
--- return a provider promise. The row->record transformation happens inside the
--- single promise, so providers never need chaining support.
---
--- NOTE: terminals are annotated with a typed promise (e.g. NormRecordListPromise)
--- so `:await()` knows the resolved type. At runtime you get the configured
--- provider's promise; await it with `:await()` or chain per your provider.
local class = class;
local sqlmod = require("sql");
local utils = require("utils");

---@class NormQueryBuilder: LightClass
---@field model NormModel
---@field private _state NormQueryState
---@overload fun(model: NormModel): NormQueryBuilder
local NormQueryBuilder = class.new("NormQueryBuilder");

---@private
---@param model NormModel
function NormQueryBuilder:__init(model)
    self.model = model;
    self._state = {
        table = model.table,
        columns = nil,
        raw_columns = nil,
        joins = nil,
        wheres = {},
        groups = nil,
        havings = nil,
        orders = {},
        limit = nil,
        offset = nil,
        includes = nil,
        trashed = nil, -- nil = exclude soft-deleted; "with" = include; "only" = only trashed
    };
end

--- Build the query state actually sent to SQL, applying the soft-delete scope for
--- soft-delete models (excluded by default; honours `with_trashed`/`only_trashed`).
---@private
---@return NormQueryState
function NormQueryBuilder:_effective_state()
    local model = self.model;
    local trashed = self._state.trashed;
    if (not model.soft_deletes or trashed == "with") then
        return self._state;
    end
    local s = {};
    for k, v in pairs(self._state) do s[k] = v; end
    local wheres = {};
    for i = 1, #self._state.wheres do wheres[i] = self._state.wheres[i]; end
    -- nil value -> compiled as IS NULL ("=") / IS NOT NULL ("!=").
    wheres[#wheres + 1] = { column = model.soft_deletes, op = (trashed == "only") and "!=" or "=", bool = "AND" };
    s.wheres = wheres;
    return s;
end

--- Include soft-deleted rows in the result (disables the default exclusion).
---@return NormQueryBuilder self
function NormQueryBuilder:with_trashed() self._state.trashed = "with"; return self; end

--- Return ONLY soft-deleted rows.
---@return NormQueryBuilder self
function NormQueryBuilder:only_trashed() self._state.trashed = "only"; return self; end

---@param self NormQueryBuilder
---@param jtype "INNER"|"LEFT"
---@param table_name string
---@param first string
---@param op string
---@param second? string
---@return NormQueryBuilder self
local function add_join(self, jtype, table_name, first, op, second)
    if (second == nil) then second = op; op = "="; end
    self._state.joins = self._state.joins or {};
    self._state.joins[#self._state.joins + 1] =
        { type = jtype, table = table_name, first = first, op = op, second = second };
    return self;
end

--- Build a correlated subquery `(SELECT <inner> FROM <related…> WHERE related.fk =
--- parent.key [AND <configure conditions>])` for a relation — the engine behind
--- `where_has` (inner = "1") and `with_count` (inner = "COUNT(*)"). Soft-deleted
--- related rows are excluded. Returns (sql, params).
---@param self NormQueryBuilder
---@param rel NormRelation
---@param inner_select string
---@param configure? fun(q: NormQueryBuilder)
---@return string sql, any[] params
local function relation_subquery(self, rel, inner_select, configure)
    local model = self.model;
    local orm = model.orm;
    local target = orm:model(rel.target);
    assert(target, ("[norm] relation '%s': target '%s' is not defined"):format(rel.name or "?", rel.target));
    local d = orm.adapter:get_dialect();
    local params, wheres = {}, {};

    if (configure) then
        local sub = NormQueryBuilder(target);
        configure(sub);
        for i = 1, #sub._state.wheres do wheres[#wheres + 1] = sub._state.wheres[i]; end
    end
    if (target.soft_deletes) then
        wheres[#wheres + 1] = { raw = sqlmod.quote_ref(d, target.table .. "." .. target.soft_deletes) .. " IS NULL" };
    end

    if (rel.kind == "belongs_to_many") then
        local through = rel.through or utils.default_pivot(model.table, target.table);
        local pivot_main = rel.key;
        local pivot_other = rel.otherKey or (utils.singularize(target.table) .. "_id");
        local other_local = rel.otherLocalKey or target.primary_key;
        local local_key = rel.localKey or model.primary_key;
        table.insert(wheres, 1, { raw = sqlmod.quote_ref(d, through .. "." .. pivot_main)
            .. " = " .. sqlmod.quote_ref(d, model.table .. "." .. local_key) });
        local clause = sqlmod.compile_where(wheres, d, params);
        local from = ("%s INNER JOIN %s ON %s = %s"):format(
            d.quote(through), d.quote(target.table),
            sqlmod.quote_ref(d, target.table .. "." .. other_local),
            sqlmod.quote_ref(d, through .. "." .. pivot_other));
        return ("(SELECT %s FROM %s%s)"):format(inner_select, from, clause), params;
    end

    local corr;
    if (rel.kind == "belongs_to") then
        local other_key = rel.otherKey or target.primary_key;
        corr = sqlmod.quote_ref(d, target.table .. "." .. other_key)
            .. " = " .. sqlmod.quote_ref(d, model.table .. "." .. rel.key);
    else -- has_one / has_many
        local local_key = rel.localKey or model.primary_key;
        corr = sqlmod.quote_ref(d, target.table .. "." .. rel.key)
            .. " = " .. sqlmod.quote_ref(d, model.table .. "." .. local_key);
    end
    table.insert(wheres, 1, { raw = corr });
    local clause = sqlmod.compile_where(wheres, d, params);
    return ("(SELECT %s FROM %s%s)"):format(inner_select, d.quote(target.table), clause), params;
end

--- Eager-load relations with the result (one batched query per relation level —
--- no N+1), attaching them to each returned record. Three forms:
---   * `include("posts", "profile")` — simple relation names.
---   * `include("posts.comments")` — nested via a dotted path (shared prefixes load once).
---   * `include("posts", function(q) ... end)` — with per-relation options: call
---     `where` / `order` / `limit` / `offset` (and nested `include`) on `q`. The
---     `limit` is applied PER PARENT (e.g. 5 latest posts for each user).
--- ```lua
---     local users = User:query():include("posts.comments"):all():await()
---     print(#users[1].posts[1].comments)
---
---     local u = User:query():include("posts", function(q)
---         q:where("published", true):order("created_at", "DESC"):limit(5)
---          :include("comments", function(c) c:order("created_at", "ASC") end)
---     end):all():await()
--- ```
---@param ... string|fun(q: NormQueryBuilder) relation names/paths, or a single name + configurator
---@return NormQueryBuilder self
function NormQueryBuilder:include(...)
    local args = { ... };
    self._state.includes = self._state.includes or {};

    -- configurator form: include(name, function(q) ... end)
    if (#args == 2 and type(args[2]) == "function") then
        local name, configure = args[1], args[2];
        local rel = self.model.relations[name];
        assert(rel, ("[norm] include: model '%s' has no relation '%s'"):format(self.model.table, name));
        local target = self.model.orm:model(rel.target);
        assert(target, ("[norm] include: relation '%s' target '%s' is not defined"):format(name, rel.target));
        local sub = NormQueryBuilder(target); -- a builder for the related model; we harvest its state
        configure(sub);
        local spec = self._state.includes[name] or { wheres = {}, orders = {}, children = {} };
        spec.wheres = sub._state.wheres;
        spec.orders = sub._state.orders;
        spec.limit = sub._state.limit;
        spec.offset = sub._state.offset;
        spec.children = sub._state.includes or {};
        self._state.includes[name] = spec;
        return self;
    end

    -- string form: one or more (possibly dotted) paths.
    for i = 1, #args do
        local node = self._state.includes;
        for seg in tostring(args[i]):gmatch("[^.]+") do
            local spec = node[seg];
            if (not spec) then spec = { wheres = {}, orders = {}, children = {} }; node[seg] = spec; end
            node = spec.children;
        end
    end
    return self;
end

--- Apply a named scope (a reusable query fragment registered on the model with
--- `Model:scope(name, fn)`), passing it any extra args. Chainable.
--- ```lua
---     User:active():scope("older_than", 18):all():await()
--- ```
---@param name string
---@param ... any args forwarded to the scope function
---@return NormQueryBuilder self
function NormQueryBuilder:scope(name, ...)
    local fn = self.model.scopes and self.model.scopes[name];
    assert(fn, ("[norm] no scope '%s' on model '%s'"):format(tostring(name), self.model.table));
    fn(self, ...);
    return self;
end

--- Restrict selected columns (the inverse is `:omit`).
--- ```lua
---     User:query():select("id", "name"):all():await()
--- ```
---@param ... string|string[]
---@return NormQueryBuilder self
function NormQueryBuilder:select(...)
    local args = { ... };
    if (#args == 1 and type(args[1]) == "table") then args = args[1]; end
    self._state.columns = args;
    return self;
end

--- Inverse of `select`: select every column of the model EXCEPT the given ones
--- (e.g. to drop a `password` / large blob without listing all the others). The
--- omitted columns are simply absent from the returned records.
--- ```lua
---     local u = User:omit("password"):find(1):await()
--- ```
---@param ... string|string[]
---@return NormQueryBuilder self
function NormQueryBuilder:omit(...)
    local omitted = { ... };
    if (#omitted == 1 and type(omitted[1]) == "table") then omitted = omitted[1]; end
    local skip = {};
    for i = 1, #omitted do skip[omitted[i]] = true; end
    local cols = {};
    for i = 1, #self.model.columns do
        local name = self.model.columns[i].name;
        if (not skip[name]) then cols[#cols + 1] = name; end
    end
    self._state.columns = cols;
    return self;
end

--- Add a RAW (unquoted) select expression — for aggregates/computed columns that
--- the column-quoting `select` can't express. Pair with `:group_by` and `:rows()`.
--- ```lua
---     User:select_raw("faction, COUNT(*) AS n"):group_by("faction"):rows():await()
--- ```
---@param expr string
---@return NormQueryBuilder self
function NormQueryBuilder:select_raw(expr)
    self._state.raw_columns = self._state.raw_columns or {};
    self._state.raw_columns[#self._state.raw_columns + 1] = expr;
    return self;
end

--- INNER JOIN another table. Use qualified `table.column` refs. Forms:
--- `join(table, first, second)` (defaults `=`) or `join(table, first, op, second)`.
--- Joins are for FILTERING/SORTING by a related table — combine with qualified
--- `where`/`order`. Since joined rows mix columns from both tables, restrict the
--- projection with `:select_raw("main.*")` if you still want `:all()` to wrap the
--- main model, or read the flattened rows with `:rows()`.
--- ```lua
---     Post:join("users", "users.id", "posts.user_id")
---         :where("users.admin", true):select_raw("`posts`.*"):all():await()
--- ```
---@param table_name string
---@param first string
---@param op string Operator, or the right column when called with 3 args.
---@param second? string
---@return NormQueryBuilder self
function NormQueryBuilder:join(table_name, first, op, second)
    return add_join(self, "INNER", table_name, first, op, second);
end

--- LEFT JOIN another table (same argument forms as `:join`). Keeps main rows even
--- when there is no match on the joined side.
---@param table_name string
---@param first string
---@param op string
---@param second? string
---@return NormQueryBuilder self
function NormQueryBuilder:left_join(table_name, first, op, second)
    return add_join(self, "LEFT", table_name, first, op, second);
end

---@param self NormQueryBuilder
---@param column string|table<string, any>
---@param op? string
---@param value? any
---@param bool "AND"|"OR"
---@return NormQueryBuilder self
local function push_where(self, column, op, value, bool)
    if (type(column) == "table") then
        for k, v in pairs(column) do
            self._state.wheres[#self._state.wheres + 1] =
                { column = k, op = "=", value = v, bool = bool };
        end
        return self;
    end
    if (value == nil) then value = op; op = "="; end
    self._state.wheres[#self._state.wheres + 1] =
        { column = column, op = op, value = value, bool = bool };
    return self;
end

--- Add an AND condition. Forms: `where(col, value)`, `where(col, op, value)` or
--- `where({ col = value, ... })`. Chainable with the other `where_*` helpers.
--- ```lua
---     User:query():where("coins", ">", 100):where("admin", true):all():await()
--- ```
---@param column string|table<string, any>
---@param op? string Operator, or the value when called with 2 args.
---@param value? any
---@return NormQueryBuilder self
function NormQueryBuilder:where(column, op, value)
    return push_where(self, column, op, value, "AND");
end

--- OR variant of `where`.
--- ```lua
---     User:query():where("admin", true):or_where("coins", ">", 1000):all():await()
--- ```
---@param column string|table<string, any>
---@param op? string
---@param value? any
---@return NormQueryBuilder self
function NormQueryBuilder:or_where(column, op, value)
    return push_where(self, column, op, value, "OR");
end

-- Append a where condition with an explicit conjunction.
---@param self NormQueryBuilder
local function push(self, cond, bool)
    cond.bool = bool;
    self._state.wheres[#self._state.wheres + 1] = cond;
    return self;
end

--- `column IN (...)` (and its OR / negated variants).
--- ```lua
---     User:query():where_in("id", { 1, 2, 3 }):all():await()
--- ```
---@param column string
---@param list any[]
---@return NormQueryBuilder self
function NormQueryBuilder:where_in(column, list) return push(self, { column = column, op = "IN", value = list }, "AND"); end
---@param column string
---@param list any[]
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_in(column, list) return push(self, { column = column, op = "IN", value = list }, "OR"); end
---@param column string
---@param list any[]
---@return NormQueryBuilder self
function NormQueryBuilder:where_not_in(column, list) return push(self, { column = column, op = "NOT IN", value = list }, "AND"); end
---@param column string
---@param list any[]
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_not_in(column, list) return push(self, { column = column, op = "NOT IN", value = list }, "OR"); end

--- `column IS [NOT] NULL` (and OR variants).
---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:where_null(column) return push(self, { column = column, op = "=" }, "AND"); end
---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_null(column) return push(self, { column = column, op = "=" }, "OR"); end
---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:where_not_null(column) return push(self, { column = column, op = "!=" }, "AND"); end
---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_not_null(column) return push(self, { column = column, op = "!=" }, "OR"); end

--- `column != value` (and OR variant).
---@param column string
---@param value any
---@return NormQueryBuilder self
function NormQueryBuilder:where_not(column, value) return push(self, { column = column, op = "!=", value = value }, "AND"); end
---@param column string
---@param value any
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_not(column, value) return push(self, { column = column, op = "!=", value = value }, "OR"); end

--- `column [NOT] LIKE pattern` (use `%` / `_` wildcards). With OR / negated variants.
--- ```lua
---     User:query():where_like("name", "John%"):all():await()
--- ```
---@param column string
---@param pattern string
---@return NormQueryBuilder self
function NormQueryBuilder:where_like(column, pattern) return push(self, { column = column, op = "LIKE", value = pattern }, "AND"); end
---@param column string
---@param pattern string
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_like(column, pattern) return push(self, { column = column, op = "LIKE", value = pattern }, "OR"); end
---@param column string
---@param pattern string
---@return NormQueryBuilder self
function NormQueryBuilder:where_not_like(column, pattern) return push(self, { column = column, op = "NOT LIKE", value = pattern }, "AND"); end
---@param column string
---@param pattern string
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_not_like(column, pattern) return push(self, { column = column, op = "NOT LIKE", value = pattern }, "OR"); end

--- `column [NOT] BETWEEN min AND max` (inclusive). With OR / negated variants.
--- ```lua
---     Player:query():where_between("level", 10, 20):all():await()
--- ```
---@param column string
---@param min any
---@param max any
---@return NormQueryBuilder self
function NormQueryBuilder:where_between(column, min, max) return push(self, { column = column, op = "BETWEEN", value = { min, max } }, "AND"); end
---@param column string
---@param min any
---@param max any
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_between(column, min, max) return push(self, { column = column, op = "BETWEEN", value = { min, max } }, "OR"); end
---@param column string
---@param min any
---@param max any
---@return NormQueryBuilder self
function NormQueryBuilder:where_not_between(column, min, max) return push(self, { column = column, op = "NOT BETWEEN", value = { min, max } }, "AND"); end
---@param column string
---@param min any
---@param max any
---@return NormQueryBuilder self
function NormQueryBuilder:or_where_not_between(column, min, max) return push(self, { column = column, op = "NOT BETWEEN", value = { min, max } }, "OR"); end

--- Keep only rows that HAVE at least one related row for `name` (optionally
--- matching the `configure` conditions). Compiles to `EXISTS (correlated subquery)`.
--- ```lua
---     User:where_has("posts"):all():await()                       -- users with any post
---     User:where_has("posts", function(q) q:where("published", true) end):all():await()
--- ```
---@param name string Relation name.
---@param configure? fun(q: NormQueryBuilder) Conditions on the related rows.
---@return NormQueryBuilder self
function NormQueryBuilder:where_has(name, configure)
    local rel = self.model.relations[name];
    assert(rel, ("[norm] where_has: model '%s' has no relation '%s'"):format(self.model.table, name));
    local sql, params = relation_subquery(self, rel, "1", configure);
    self._state.wheres[#self._state.wheres + 1] = { exists = true, negate = false, sql = sql, params = params, bool = "AND" };
    return self;
end

--- Inverse of `where_has`: keep only rows with NO matching related row
--- (`NOT EXISTS (...)`).
---@param name string Relation name.
---@param configure? fun(q: NormQueryBuilder)
---@return NormQueryBuilder self
function NormQueryBuilder:where_doesnt_have(name, configure)
    local rel = self.model.relations[name];
    assert(rel, ("[norm] where_doesnt_have: model '%s' has no relation '%s'"):format(self.model.table, name));
    local sql, params = relation_subquery(self, rel, "1", configure);
    self._state.wheres[#self._state.wheres + 1] = { exists = true, negate = true, sql = sql, params = params, bool = "AND" };
    return self;
end

--- Add a `<name>_count` field to each returned record: the number of related rows,
--- without loading them (a correlated `COUNT(*)` subquery). Soft-deleted related
--- rows aren't counted.
--- ```lua
---     local users = User:with_count("posts"):all():await()
---     print(users[1].posts_count)
--- ```
---@param ... string relation names
---@return NormQueryBuilder self
function NormQueryBuilder:with_count(...)
    self._state.with_counts = self._state.with_counts or {};
    local names = { ... };
    for i = 1, #names do self._state.with_counts[#self._state.with_counts + 1] = names[i]; end
    return self;
end

--- Internal: fold `with_count` relations into a select state (adds `*` + the count
--- subqueries to `raw_columns`). Returns (state, counts) — counts is nil if none.
---@private
---@param state NormQueryState
---@return NormQueryState state, string[]|nil counts
function NormQueryBuilder:_prepare_counts(state)
    local counts = self._state.with_counts;
    if (not counts or #counts == 0) then return state, nil; end
    local d = self.model.orm.adapter:get_dialect();
    local s = {};
    for k, v in pairs(state) do s[k] = v; end
    s.raw_columns = {};
    if (state.raw_columns) then for i = 1, #state.raw_columns do s.raw_columns[i] = state.raw_columns[i]; end end
    if (not s.columns or #s.columns == 0) then s.raw_columns[#s.raw_columns + 1] = "*"; end
    for i = 1, #counts do
        local rel = self.model.relations[counts[i]];
        assert(rel, ("[norm] with_count: model '%s' has no relation '%s'"):format(self.model.table, counts[i]));
        local sub = relation_subquery(self, rel, "COUNT(*)", nil); -- param-free (no configure)
        s.raw_columns[#s.raw_columns + 1] = sub .. " AS " .. d.quote(counts[i] .. "_count");
    end
    return s, counts;
end

--- Add an ORDER BY clause (call again for secondary orderings).
--- ```lua
---     User:query():order("coins", "DESC"):order("name"):all():await()
--- ```
---@param column string
---@param dir? "ASC"|"DESC"
---@return NormQueryBuilder self
function NormQueryBuilder:order(column, dir)
    self._state.orders[#self._state.orders + 1] =
        { column = column, dir = (dir or "ASC"):upper() };
    return self;
end

--- Limit the number of rows (pair with `:offset()` for pagination).
--- ```lua
---     local page = User:query():order("id"):limit(10):offset(20):all():await()
--- ```
---@param n number
---@return NormQueryBuilder self
function NormQueryBuilder:limit(n) self._state.limit = n; return self; end

--- Skip `n` rows (use with `:limit()`).
---@param n number
---@return NormQueryBuilder self
function NormQueryBuilder:offset(n) self._state.offset = n; return self; end

--- Add GROUP BY columns (call again, or pass several, to group by more).
--- ```lua
---     Player:select_raw("faction, COUNT(*) AS n"):group_by("faction"):rows():await()
--- ```
---@param ... string
---@return NormQueryBuilder self
function NormQueryBuilder:group_by(...)
    self._state.groups = self._state.groups or {};
    local args = { ... };
    for i = 1, #args do self._state.groups[#self._state.groups + 1] = args[i]; end
    return self;
end

--- Add a HAVING condition (ANDed) on a RAW aggregate expression. Forms:
--- `having(expr, value)` or `having(expr, op, value)`. The expression is emitted
--- verbatim (so you can reference `COUNT(*)`, `SUM(\`coins\`)`, …); the value is bound.
--- ```lua
---     Player:select_raw("faction, COUNT(*) AS n"):group_by("faction")
---           :having("COUNT(*)", ">", 10):rows():await()
--- ```
---@param expr string Raw SQL expression (not quoted).
---@param op? string Operator, or the value when called with 2 args.
---@param value? any
---@return NormQueryBuilder self
function NormQueryBuilder:having(expr, op, value)
    if (value == nil) then value = op; op = "="; end
    self._state.havings = self._state.havings or {};
    self._state.havings[#self._state.havings + 1] = { expr = expr, op = op, value = value };
    return self;
end

-- ---------- terminal methods (return promises) ----------

--- Execute the query and resolve with all matching records.
--- ```lua
---     local users = User:query():where("admin", true):all():await()
--- ```
---@return NormRecordListPromise promise resolving to NormRecord[]
function NormQueryBuilder:all()
    local model = self.model;
    local includes = self._state.includes;
    local state, counts = self:_prepare_counts(self:_effective_state());
    if (includes and next(includes) ~= nil) then
        return model.orm:_query_with_includes(model, state, includes, false);
    end
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.select(state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local out = {};
        for i = 1, #rows do
            local rec = model:wrap(rows[i]);
            if (counts) then
                for j = 1, #counts do rec[counts[j] .. "_count"] = tonumber(rows[i][counts[j] .. "_count"]) or 0; end
            end
            out[i] = rec;
        end
        return out;
    end);
end

--- Execute the query with LIMIT 1 and resolve with the first record (or nil).
--- ```lua
---     local newest = User:query():order("id", "DESC"):first():await()
--- ```
---@return NormRecordOrNilPromise promise resolving to NormRecord|nil
function NormQueryBuilder:first()
    self._state.limit = 1;
    local model = self.model;
    local includes = self._state.includes;
    local state, counts = self:_prepare_counts(self:_effective_state());
    if (includes and next(includes) ~= nil) then
        return model.orm:_query_with_includes(model, state, includes, true);
    end
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.select(state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local row = rows[1];
        if (not row) then return nil; end
        local rec = model:wrap(row);
        if (counts) then
            for j = 1, #counts do rec[counts[j] .. "_count"] = tonumber(row[counts[j] .. "_count"]) or 0; end
        end
        return rec;
    end);
end

--- Resolve with the COUNT(*) for the current conditions.
--- ```lua
---     local admins = User:query():where("admin", true):count():await()
--- ```
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:count()
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.count(self:_effective_state(), d);
    return model.orm:_query_map(statement, params, function(rows)
        local row = rows[1] or {};
        return tonumber(row.count or row.COUNT or row["COUNT(*)"]) or 0;
    end);
end

--- Paginate the current query. Runs a `COUNT(*)` over the filter plus a
--- `LIMIT/OFFSET` page query, resolving with
--- `{ data, total, page, per_page, last_page, from, to }`. Honours `where`,
--- `order`, soft-delete scope, and `with_count`.
--- ```lua
---     local p = User:where("admin", true):order("name"):paginate(2, 20):await()
---     print(p.page, p.last_page, #p.data, p.total)
--- ```
---@param page? number 1-based page (default 1).
---@param per_page? number rows per page (default 15).
---@return NormPromise promise resolving to a pagination table
function NormQueryBuilder:paginate(page, per_page)
    page = math.max(1, math.floor(page or 1));
    per_page = math.max(1, math.floor(per_page or 15));
    local model = self.model;
    local orm = model.orm;
    local d = orm.adapter:get_dialect();

    local effective = self:_effective_state();
    local count_sql, count_params = sqlmod.count({ table = effective.table, wheres = effective.wheres }, d);

    local data_state, counts = self:_prepare_counts(effective);
    local ds = {};
    for k, v in pairs(data_state) do ds[k] = v; end
    ds.limit = per_page;
    ds.offset = (page - 1) * per_page;
    local data_sql, data_params = sqlmod.select(ds, d);

    return orm.provider.new(function(resolve, reject)
        orm:_trace(count_sql, count_params);
        orm:_raw_query(count_sql, count_params, function(cerr, crows)
            if (cerr ~= nil) then return reject(cerr); end
            local total = tonumber(((crows or {})[1] or {}).count) or 0;
            orm:_trace(data_sql, data_params);
            orm:_raw_query(data_sql, data_params, function(derr, drows)
                if (derr ~= nil) then return reject(derr); end
                drows = drows or {};
                local data = {};
                for i = 1, #drows do
                    local rec = model:wrap(drows[i]);
                    if (counts) then
                        for j = 1, #counts do rec[counts[j] .. "_count"] = tonumber(drows[i][counts[j] .. "_count"]) or 0; end
                    end
                    data[i] = rec;
                end
                resolve({
                    data = data,
                    total = total,
                    page = page,
                    per_page = per_page,
                    last_page = math.max(1, math.ceil(total / per_page)),
                    from = (#data > 0) and (ds.offset + 1) or 0,
                    to = ds.offset + #data,
                });
            end);
        end);
    end);
end

--- Execute the query and resolve with the RAW rows (no record wrapping). Use this
--- for grouped aggregates built with `:select_raw` / `:group_by` / `:having`.
--- ```lua
---     local stats = Player:select_raw("faction, COUNT(*) AS n, SUM(`coins`) AS total")
---         :group_by("faction"):having("COUNT(*)", ">", 10):rows():await()
--- ```
---@return NormRowsPromise promise resolving to table[]
function NormQueryBuilder:rows()
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.select(self:_effective_state(), d);
    return model.orm:_query_map(statement, params, function(rows) return rows; end);
end

--- Run a scalar aggregate over the current WHERE filter, resolving the value.
---@param self NormQueryBuilder
---@param func string
---@param column? string
---@param numeric boolean Coerce the result with tonumber (SUM/AVG/COUNT).
---@return NormNumberPromise
local function aggregate(self, func, column, numeric)
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.aggregate(self:_effective_state(), func, column, d);
    return model.orm:_query_map(statement, params, function(rows)
        local value = (rows[1] or {}).aggregate;
        if (numeric) then return tonumber(value) or 0; end
        return value;
    end);
end

--- SUM of a column over the current filter. Resolves with a number (0 if empty).
--- ```lua
---     local bank = User:where("admin", false):sum("coins"):await()
--- ```
---@param column string
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:sum(column) return aggregate(self, "SUM", column, true); end

--- AVG of a column over the current filter. Resolves with a number.
---@param column string
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:avg(column) return aggregate(self, "AVG", column, true); end

--- MIN of a column over the current filter. Resolves with the raw value.
---@param column string
---@return NormNumberPromise promise resolving to the column's value type
function NormQueryBuilder:min(column) return aggregate(self, "MIN", column, false); end

--- MAX of a column over the current filter. Resolves with the raw value.
--- ```lua
---     local top = Player:max("score"):await()
--- ```
---@param column string
---@return NormNumberPromise promise resolving to the column's value type
function NormQueryBuilder:max(column) return aggregate(self, "MAX", column, false); end

--- Bulk-update every matching row in one statement (no records loaded).
--- Resolves with the affected row count.
--- ```lua
---     local n = User:query():where("admin", true):update({ coins = 0 }):await()
--- ```
---@param data table<string, any>
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:update(data)
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    -- Don't update rows already soft-deleted (unless with_trashed/only_trashed).
    local statement, params = sqlmod.update(self:_effective_state(), model:_encode_write(data), d);
    return model.orm:_execute_map(statement, params, function(res)
        return res and res.affectedRows or 0;
    end);
end

--- Bulk-delete every matching row. On a soft-delete model this marks the rows
--- (sets `deleted_at`) rather than removing them; use `force_delete` to remove.
--- Resolves with the affected row count.
--- ```lua
---     local n = User:query():where("coins", 0):delete():await()
--- ```
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:delete()
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    if (model.soft_deletes) then
        -- soft: UPDATE deleted_at = now over the (non-trashed) matched rows.
        local statement, params = sqlmod.update(self:_effective_state(), { [model.soft_deletes] = utils.now_utc() }, d);
        return model.orm:_execute_map(statement, params, function(res)
            return res and res.affectedRows or 0;
        end);
    end
    local statement, params = sqlmod.delete(self._state, d);
    return model.orm:_execute_map(statement, params, function(res)
        return res and res.affectedRows or 0;
    end);
end

--- Atomically add `amount` (default 1) to a column on every matching row, in one
--- `SET col = col + ?` statement (no read-modify-write, race-free). Resolves with
--- the affected row count.
--- ```lua
---     Player:where("id", id):increment("coins", 50):await()
--- ```
---@param column string
---@param amount? number Defaults to 1.
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:increment(column, amount)
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.increment(self:_effective_state(), { { column = column, amount = amount or 1 } }, d);
    return model.orm:_execute_map(statement, params, function(res) return res and res.affectedRows or 0; end);
end

--- Atomically subtract `amount` (default 1) from a column on every matching row.
---@param column string
---@param amount? number Defaults to 1.
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:decrement(column, amount)
    return self:increment(column, -(amount or 1));
end

--- Bulk physical-DELETE every matching row, even on a soft-delete model.
--- Resolves with the affected row count.
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:force_delete()
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.delete(self._state, d);
    return model.orm:_execute_map(statement, params, function(res)
        return res and res.affectedRows or 0;
    end);
end

return NormQueryBuilder;
