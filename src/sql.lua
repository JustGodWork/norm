--- Pure SQL string builders. They turn model metadata + query state into a
--- parameterised SQL string and a params array. No database access -> testable.
local utils = require("utils");

---@class NormWhere
---@field column string
---@field op string Operator: "=", "!=", "<", ">", "<=", ">=", "LIKE", "IN", "NOT IN".
---@field value any `nil` -> IS [NOT] NULL. For IN/NOT IN an array.
---@field bool? "AND"|"OR" Conjunction with the previous condition.

---@class NormOrder
---@field column string
---@field dir "ASC"|"DESC"

---@class NormQueryState
---@field table string
---@field columns? string[] Selected columns (nil = "*").
---@field wheres NormWhere[]
---@field orders? NormOrder[]
---@field limit? number
---@field offset? number

---@class NormSql
local sql = {};

--- Normalise a Lua value into something a driver can bind.
---@param value any
---@return any
local function normalize(value)
    if (type(value) == "boolean") then return value and 1 or 0; end
    return value;
end
sql.normalize = normalize;

--- Build the column definition fragment for CREATE TABLE.
---@param column NormColumn
---@param d NormDialect
---@return string
local function column_def(column, d)
    -- SQLite needs the exact "INTEGER PRIMARY KEY AUTOINCREMENT" spelling.
    if (column.primary and d.name == "sqlite") then
        local def = d.quote(column.name) .. " INTEGER PRIMARY KEY";
        if (column.autoincrement) then def = def .. " AUTOINCREMENT"; end
        return def;
    end

    local type_sql = d.types[column.kind] or "TEXT";
    if (column.kind == "string" and column.length and d.name ~= "sqlite") then
        type_sql = ("VARCHAR(%d)"):format(column.length);
    end

    local def = d.quote(column.name) .. " " .. type_sql;

    if (column.primary) then
        def = def .. " PRIMARY KEY";
        if (column.autoincrement) then def = def .. " " .. d.autoincrement; end
    else
        if (not column.nullable) then def = def .. " NOT NULL"; end
        if (column.unique) then def = def .. " UNIQUE"; end
    end

    if (column.default ~= nil) then
        if (type(column.default) == "table" and column.default.__raw) then
            def = def .. " DEFAULT " .. column.default.__raw;
        elseif (type(column.default) == "string") then
            def = def .. " DEFAULT '" .. column.default:gsub("'", "''") .. "'";
        elseif (type(column.default) == "boolean") then
            def = def .. " DEFAULT " .. (column.default and "1" or "0");
        else
            def = def .. " DEFAULT " .. tostring(column.default);
        end
    end

    return def;
end

--- A foreign-key constraint to emit inside CREATE TABLE.
---@class NormForeignKey
---@field column string FK column on this table.
---@field ref_table string Referenced table.
---@field ref_column string Referenced column.
---@field on_delete? string Referential action (e.g. "CASCADE").
---@field on_update? string Referential action (e.g. "CASCADE").

--- Build a `FOREIGN KEY (...) REFERENCES ...` table constraint fragment. Works
--- for both MySQL (inline) and SQLite (inline, forward references allowed).
---@param fk NormForeignKey
---@param d NormDialect
---@return string
local function foreign_key_def(fk, d)
    local frag = ("FOREIGN KEY (%s) REFERENCES %s (%s)"):format(
        d.quote(fk.column), d.quote(fk.ref_table), d.quote(fk.ref_column));
    if (fk.on_delete) then frag = frag .. " ON DELETE " .. tostring(fk.on_delete):upper(); end
    if (fk.on_update) then frag = frag .. " ON UPDATE " .. tostring(fk.on_update):upper(); end
    return frag;
end
sql.foreign_key_def = foreign_key_def;

--- CREATE TABLE IF NOT EXISTS. Pass `foreign_keys` to append `FOREIGN KEY`
--- constraints (the caller decides whether to emit them per dialect/options).
---@param table_name string
---@param columns NormColumn[] Ordered list (each has a `.name`).
---@param d NormDialect
---@param foreign_keys? NormForeignKey[] Optional FK constraints to append.
---@return string statement
function sql.create_table(table_name, columns, d, foreign_keys)
    local parts = {};
    for i = 1, #columns do parts[#parts + 1] = column_def(columns[i], d); end
    if (foreign_keys) then
        for i = 1, #foreign_keys do parts[#parts + 1] = foreign_key_def(foreign_keys[i], d); end
    end
    return ("CREATE TABLE IF NOT EXISTS %s (%s)%s"):format(
        d.quote(table_name), table.concat(parts, ", "), d.table_suffix);
end

--- INSERT.
---@param table_name string
---@param data table<string, any>
---@param d NormDialect
---@return string statement, any[] params
function sql.insert(table_name, data, d)
    local cols, marks, params = {}, {}, {};
    for _, key in ipairs(utils.sorted_keys(data)) do
        local value = data[key];
        cols[#cols + 1] = d.quote(key);
        if (value == nil) then
            marks[#marks + 1] = "NULL";
        else
            params[#params + 1] = normalize(value);
            marks[#marks + 1] = d.placeholder(#params);
        end
    end
    return ("INSERT INTO %s (%s) VALUES (%s)"):format(
        d.quote(table_name), table.concat(cols, ", "), table.concat(marks, ", ")), params;
end

--- Compile WHERE conditions into a fragment, appending bound params.
--- op "IN"/"NOT IN" expects an array value; nil value -> IS [NOT] NULL.
---@param wheres NormWhere[]
---@param d NormDialect
---@param params any[] Params array to append to (mutated).
---@return string clause
local function compile_where(wheres, d, params)
    if (#wheres == 0) then return ""; end
    local fragments = {};
    for i = 1, #wheres do
        local cond = wheres[i];
        local col = d.quote(cond.column);
        local op = (cond.op or "="):upper();
        local frag;

        if (cond.value == nil) then
            local negated = (op == "!=" or op == "<>" or op == "NOT");
            frag = col .. (negated and " IS NOT NULL" or " IS NULL");
        elseif (op == "IN" or op == "NOT IN") then
            local marks = {};
            for j = 1, #cond.value do
                params[#params + 1] = normalize(cond.value[j]);
                marks[#marks + 1] = d.placeholder(#params);
            end
            frag = ("%s %s (%s)"):format(col, op, table.concat(marks, ", "));
        else
            params[#params + 1] = normalize(cond.value);
            frag = ("%s %s %s"):format(col, op, d.placeholder(#params));
        end

        if (i == 1) then
            fragments[#fragments + 1] = frag;
        else
            fragments[#fragments + 1] = (cond.bool or "AND") .. " " .. frag;
        end
    end
    return " WHERE " .. table.concat(fragments, " ");
end
sql.compile_where = compile_where;

--- SELECT from a query-builder state.
---@param state NormQueryState
---@param d NormDialect
---@return string statement, any[] params
function sql.select(state, d)
    local params = {};
    local columns = "*";
    if (state.columns and #state.columns > 0) then
        local quoted = {};
        for i = 1, #state.columns do quoted[i] = d.quote(state.columns[i]); end
        columns = table.concat(quoted, ", ");
    end

    local statement = ("SELECT %s FROM %s"):format(columns, d.quote(state.table));
    statement = statement .. compile_where(state.wheres, d, params);

    if (state.orders and #state.orders > 0) then
        local parts = {};
        for i = 1, #state.orders do
            local o = state.orders[i];
            parts[#parts + 1] = d.quote(o.column) .. " " .. (o.dir or "ASC");
        end
        statement = statement .. " ORDER BY " .. table.concat(parts, ", ");
    end

    if (state.limit) then
        statement = statement .. " LIMIT " .. tostring(math.floor(state.limit));
        if (state.offset) then
            statement = statement .. " OFFSET " .. tostring(math.floor(state.offset));
        end
    end

    return statement, params;
end

--- SELECT COUNT(*).
---@param state NormQueryState
---@param d NormDialect
---@return string statement, any[] params
function sql.count(state, d)
    local params = {};
    local statement = ("SELECT COUNT(*) AS %s FROM %s"):format(d.quote("count"), d.quote(state.table));
    statement = statement .. compile_where(state.wheres, d, params);
    return statement, params;
end

--- UPDATE from state + data.
---@param state NormQueryState
---@param data table<string, any>
---@param d NormDialect
---@return string statement, any[] params
function sql.update(state, data, d)
    local params = {};
    local sets = {};
    for _, key in ipairs(utils.sorted_keys(data)) do
        local value = data[key];
        if (value == nil) then
            sets[#sets + 1] = d.quote(key) .. " = NULL";
        else
            params[#params + 1] = normalize(value);
            sets[#sets + 1] = d.quote(key) .. " = " .. d.placeholder(#params);
        end
    end
    local statement = ("UPDATE %s SET %s"):format(d.quote(state.table), table.concat(sets, ", "));
    statement = statement .. compile_where(state.wheres, d, params);
    return statement, params;
end

--- DELETE from state.
---@param state NormQueryState
---@param d NormDialect
---@return string statement, any[] params
function sql.delete(state, d)
    local params = {};
    local statement = ("DELETE FROM %s"):format(d.quote(state.table));
    statement = statement .. compile_where(state.wheres, d, params);
    return statement, params;
end

return sql;
