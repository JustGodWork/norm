--- Chainable query builder. Terminal methods (all/first/count/update/delete)
--- return a provider promise. The row->record transformation happens inside the
--- single promise, so providers never need chaining support.
---
--- NOTE: terminals are annotated with a typed promise (e.g. NormRecordListPromise)
--- so `:await()` knows the resolved type. At runtime you get the configured
--- provider's promise; await it with `:await()` or chain per your provider.
local class = class;
local sqlmod = require("sql");

---@class NormQueryBuilder: LightClass
---@field model NormModel
---@field private _state NormQueryState
---@overload fun(model: NormModel): NormQueryBuilder
local NormQueryBuilder = class.new("NormQueryBuilder");

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
    };
end

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

--- Restrict selected columns. select("id","name") or select({"id","name"}).
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
---@param column string|table<string, any>
---@param op? string
---@param value? any
---@return NormQueryBuilder self
function NormQueryBuilder:or_where(column, op, value)
    return push_where(self, column, op, value, "OR");
end

--- Add a `column IN (...)` condition.
--- ```lua
---     User:query():where_in("id", { 1, 2, 3 }):all():await()
--- ```
---@param column string
---@param list any[]
---@return NormQueryBuilder self
function NormQueryBuilder:where_in(column, list)
    self._state.wheres[#self._state.wheres + 1] =
        { column = column, op = "IN", value = list, bool = "AND" };
    return self;
end

---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:where_null(column)
    self._state.wheres[#self._state.wheres + 1] =
        { column = column, op = "=", value = nil, bool = "AND" };
    return self;
end

---@param column string
---@return NormQueryBuilder self
function NormQueryBuilder:where_not_null(column)
    self._state.wheres[#self._state.wheres + 1] =
        { column = column, op = "!=", value = nil, bool = "AND" };
    return self;
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
    if (includes and next(includes) ~= nil) then
        return model.orm:_query_with_includes(model, self._state, includes, false);
    end
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.select(self._state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local out = {};
        for i = 1, #rows do out[i] = model:wrap(rows[i]); end
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
    if (includes and next(includes) ~= nil) then
        return model.orm:_query_with_includes(model, self._state, includes, true);
    end
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.select(self._state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local row = rows[1];
        return row and model:wrap(row) or nil;
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
    local statement, params = sqlmod.count(self._state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local row = rows[1] or {};
        return tonumber(row.count or row.COUNT or row["COUNT(*)"]) or 0;
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
    local statement, params = sqlmod.select(self._state, d);
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
    local statement, params = sqlmod.aggregate(self._state, func, column, d);
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
    local statement, params = sqlmod.update(self._state, model:_encode_write(data), d);
    return model.orm:_execute_map(statement, params, function(res)
        return res and res.affectedRows or 0;
    end);
end

--- Bulk-delete every matching row in one statement. Resolves with the affected
--- row count.
--- ```lua
---     local n = User:query():where("coins", 0):delete():await()
--- ```
---@return NormNumberPromise promise resolving to number
function NormQueryBuilder:delete()
    local model = self.model;
    local d = model.orm.adapter:get_dialect();
    local statement, params = sqlmod.delete(self._state, d);
    return model.orm:_execute_map(statement, params, function(res)
        return res and res.affectedRows or 0;
    end);
end

return NormQueryBuilder;
