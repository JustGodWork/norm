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
        wheres = {},
        orders = {},
        limit = nil,
        offset = nil,
        includes = nil,
    };
end

--- Eager-load the given relations with the result (one batched query per
--- relation — no N+1), attaching them to each returned record.
--- ```lua
---     local users = User:query():include("posts", "profile"):all():await()
---     print(#users[1].posts)
--- ```
---@param ... string relation names declared in the model's schema
---@return NormQueryBuilder self
function NormQueryBuilder:include(...)
    self._state.includes = self._state.includes or {};
    local names = { ... };
    for i = 1, #names do
        self._state.includes[#self._state.includes + 1] = names[i];
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

-- ---------- terminal methods (return promises) ----------

--- Execute the query and resolve with all matching records.
--- ```lua
---     local users = User:query():where("admin", true):all():await()
--- ```
---@return NormRecordListPromise promise resolving to NormRecord[]
function NormQueryBuilder:all()
    local model = self.model;
    local includes = self._state.includes;
    if (includes and #includes > 0) then
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
    if (includes and #includes > 0) then
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
