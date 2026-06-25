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

---@class NormHaving
---@field expr string Raw SQL expression (NOT quoted), e.g. "COUNT(*)".
---@field op string Operator.
---@field value any Bound parameter.

---@class NormJoin
---@field type "INNER"|"LEFT" Join type.
---@field table string Joined table.
---@field first string Left column ref of the ON condition (e.g. "users.id").
---@field op string ON operator.
---@field second string Right column ref of the ON condition (e.g. "posts.user_id").

---@class NormQueryState
---@field table string
---@field columns? string[] Selected columns (nil = "*").
---@field raw_columns? string[] Raw (unquoted) select expressions, e.g. "COUNT(*) AS n".
---@field joins? NormJoin[] JOIN clauses.
---@field wheres NormWhere[]
---@field groups? string[] GROUP BY columns.
---@field havings? NormHaving[] HAVING conditions (ANDed).
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

--- Quote a column reference, qualifying each dotted segment: "users.id" ->
--- `` `users`.`id` ``. A bare name quotes whole. Used wherever a join may make
--- columns ambiguous (where / order / join ON).
---@param d NormDialect
---@param ref string
---@return string
local function quote_ref(d, ref)
    if (ref:find(".", 1, true)) then
        local parts = {};
        for seg in ref:gmatch("[^.]+") do parts[#parts + 1] = d.quote(seg); end
        return table.concat(parts, ".");
    end
    return d.quote(ref);
end
sql.quote_ref = quote_ref;

--- Render the SQL column type for an `enum` column: native `ENUM('a','b',…)` on
--- MySQL, `TEXT CHECK (col IN ('a','b',…))` on SQLite (which has no ENUM). The
--- value list is single-quoted with `'` doubled, so both engines reject anything
--- outside the set.
---@param column NormColumn
---@param d NormDialect
---@return string
local function enum_type_sql(column, d)
    local values = column.values;
    utils.assert(type(values) == "table" and #values > 0,
        ("enum column '%s' has no values"):format(tostring(column.name)));
    local quoted = {};
    for i = 1, #values do
        quoted[i] = "'" .. tostring(values[i]):gsub("'", "''") .. "'";
    end
    local list = table.concat(quoted, ", ");
    if (d.name == "sqlite") then
        return ("TEXT CHECK (%s IN (%s))"):format(d.quote(column.name), list);
    end
    return ("ENUM(%s)"):format(list);
end

--- Build the column definition fragment for CREATE TABLE.
---@param column NormColumn
---@param d NormDialect
---@return string
local function column_def(column, d)
    -- SQLite needs the exact "INTEGER PRIMARY KEY AUTOINCREMENT" spelling for an
    -- auto-increment PK. A non-autoincrement PK (e.g. a string/UUID key) must keep
    -- its real type, so only the autoincrement case takes this early path.
    if (column.primary and d.name == "sqlite" and column.autoincrement) then
        return d.quote(column.name) .. " INTEGER PRIMARY KEY AUTOINCREMENT";
    end

    local type_sql;
    if (column.kind == "enum") then
        type_sql = enum_type_sql(column, d);
    else
        type_sql = d.types[column.kind] or "TEXT";
        if (column.kind == "string" and column.length and d.name ~= "sqlite") then
            type_sql = ("VARCHAR(%d)"):format(column.length);
        end
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

--- INSERT. Pass `returning` (a column name) to append a `RETURNING <col>` clause
--- (SQLite >= 3.35 / PostgreSQL) so the new row's value comes back atomically.
---@param table_name string
---@param data table<string, any>
---@param d NormDialect
---@param returning? string Column to append in a `RETURNING` clause.
---@return string statement, any[] params
function sql.insert(table_name, data, d, returning)
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
    local statement = ("INSERT INTO %s (%s) VALUES (%s)"):format(
        d.quote(table_name), table.concat(cols, ", "), table.concat(marks, ", "));
    if (returning) then
        statement = statement .. " RETURNING " .. d.quote(returning);
    end
    return statement, params;
end

--- Multi-row INSERT: `INSERT INTO t (cols) VALUES (…), (…)`. `columns` is the
--- ordered column union; each `data_rows[i]` is an (already-encoded) `{col=value}`
--- map — a column absent from a row is written as `NULL`. Pass `returning` (a raw
--- list like "*", on RETURNING-capable engines) to get the inserted rows back.
---@param table_name string
---@param columns string[]
---@param data_rows table<string, any>[]
---@param d NormDialect
---@param returning? string Raw RETURNING list (e.g. "*").
---@return string statement, any[] params
function sql.insert_many(table_name, columns, data_rows, d, returning)
    local params, tuples = {}, {};
    local quoted = {};
    for i = 1, #columns do quoted[i] = d.quote(columns[i]); end
    for r = 1, #data_rows do
        local marks = {};
        for c = 1, #columns do
            local v = data_rows[r][columns[c]];
            if (v == nil) then
                marks[c] = "NULL";
            else
                params[#params + 1] = normalize(v);
                marks[c] = d.placeholder(#params);
            end
        end
        tuples[r] = "(" .. table.concat(marks, ", ") .. ")";
    end
    local statement = ("INSERT INTO %s (%s) VALUES %s"):format(
        d.quote(table_name), table.concat(quoted, ", "), table.concat(tuples, ", "));
    if (returning) then statement = statement .. " RETURNING " .. returning; end
    return statement, params;
end

--- INSERT with an atomic "on conflict, update" clause (upsert). Dialect-aware:
--- MySQL/MariaDB emit `ON DUPLICATE KEY UPDATE col = VALUES(col)`; SQLite/Postgres
--- emit `ON CONFLICT (target) DO UPDATE SET col = excluded.col`. `conflict_cols`
--- (the unique/PK columns) define the SQLite/Postgres target. With no `update_cols`
--- the conflict is a no-op (`DO NOTHING`).
---@param table_name string
---@param data table<string, any>
---@param conflict_cols string[] Unique/PK columns identifying a conflict.
---@param update_cols string[] Columns to overwrite on conflict (may be empty).
---@param d NormDialect
---@return string statement, any[] params
function sql.upsert(table_name, data, conflict_cols, update_cols, d)
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
    local head = ("INSERT INTO %s (%s) VALUES (%s)"):format(
        d.quote(table_name), table.concat(cols, ", "), table.concat(marks, ", "));

    if (d.name == "mysql") then
        if (#update_cols == 0) then
            -- keep the statement valid: a no-op assignment on the first conflict col.
            local c = d.quote(conflict_cols[1]);
            return head .. " ON DUPLICATE KEY UPDATE " .. c .. " = " .. c, params;
        end
        local sets = {};
        for i = 1, #update_cols do
            local c = d.quote(update_cols[i]);
            sets[#sets + 1] = ("%s = VALUES(%s)"):format(c, c);
        end
        return head .. " ON DUPLICATE KEY UPDATE " .. table.concat(sets, ", "), params;
    end

    -- sqlite / postgres
    local targets = {};
    for i = 1, #conflict_cols do targets[#targets + 1] = d.quote(conflict_cols[i]); end
    local target_clause = table.concat(targets, ", ");
    if (#update_cols == 0) then
        return head .. (" ON CONFLICT (%s) DO NOTHING"):format(target_clause), params;
    end
    local sets = {};
    for i = 1, #update_cols do
        local c = d.quote(update_cols[i]);
        sets[#sets + 1] = ("%s = excluded.%s"):format(c, c);
    end
    return head .. (" ON CONFLICT (%s) DO UPDATE SET %s"):format(target_clause, table.concat(sets, ", ")), params;
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
        local frag;

        if (cond.raw) then
            -- verbatim fragment (e.g. a correlated `tbl.a = other.b`); no params.
            frag = cond.raw;
            fragments[#fragments + 1] = (i == 1) and frag or ((cond.bool or "AND") .. " " .. frag);
            goto continue;
        elseif (cond.exists) then
            -- [NOT] EXISTS (correlated subquery); append the subquery's own params.
            frag = (cond.negate and "NOT EXISTS " or "EXISTS ") .. cond.sql;
            if (cond.params) then
                for j = 1, #cond.params do params[#params + 1] = normalize(cond.params[j]); end
            end
            fragments[#fragments + 1] = (i == 1) and frag or ((cond.bool or "AND") .. " " .. frag);
            goto continue;
        end

        local col = quote_ref(d, cond.column);
        local op = (cond.op or "="):upper();

        if (cond.value == nil) then
            local negated = (op == "!=" or op == "<>" or op == "NOT");
            frag = col .. (negated and " IS NOT NULL" or " IS NULL");
        elseif (op == "IN" or op == "NOT IN") then
            if (#cond.value == 0) then
                -- `IN ()` / `NOT IN ()` is invalid SQL. Emit a constant predicate
                -- instead: IN nothing is always false, NOT IN nothing always true.
                frag = (op == "IN") and "1 = 0" or "1 = 1";
            else
                local marks = {};
                for j = 1, #cond.value do
                    params[#params + 1] = normalize(cond.value[j]);
                    marks[#marks + 1] = d.placeholder(#params);
                end
                frag = ("%s %s (%s)"):format(col, op, table.concat(marks, ", "));
            end
        elseif (op == "BETWEEN" or op == "NOT BETWEEN") then
            params[#params + 1] = normalize(cond.value[1]);
            local lo = d.placeholder(#params);
            params[#params + 1] = normalize(cond.value[2]);
            local hi = d.placeholder(#params);
            frag = ("%s %s %s AND %s"):format(col, op, lo, hi);
        else
            params[#params + 1] = normalize(cond.value);
            frag = ("%s %s %s"):format(col, op, d.placeholder(#params));
        end

        if (i == 1) then
            fragments[#fragments + 1] = frag;
        else
            fragments[#fragments + 1] = (cond.bool or "AND") .. " " .. frag;
        end
        ::continue::
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
    local cols = {};
    if (state.columns) then
        for i = 1, #state.columns do cols[#cols + 1] = d.quote(state.columns[i]); end
    end
    if (state.raw_columns) then
        for i = 1, #state.raw_columns do cols[#cols + 1] = state.raw_columns[i]; end
    end
    local columns = (#cols > 0) and table.concat(cols, ", ") or "*";

    local statement = ("SELECT %s FROM %s"):format(columns, d.quote(state.table));

    if (state.joins and #state.joins > 0) then
        for i = 1, #state.joins do
            local j = state.joins[i];
            statement = statement .. (" %s JOIN %s ON %s %s %s"):format(
                j.type, d.quote(j.table), quote_ref(d, j.first), (j.op or "="), quote_ref(d, j.second));
        end
    end

    statement = statement .. compile_where(state.wheres, d, params);

    if (state.groups and #state.groups > 0) then
        local g = {};
        for i = 1, #state.groups do g[i] = d.quote(state.groups[i]); end
        statement = statement .. " GROUP BY " .. table.concat(g, ", ");
    end

    if (state.havings and #state.havings > 0) then
        local frags = {};
        for i = 1, #state.havings do
            local h = state.havings[i];
            params[#params + 1] = normalize(h.value);
            -- expr is a raw aggregate expression (e.g. COUNT(*)), intentionally unquoted.
            frags[#frags + 1] = ("%s %s %s"):format(h.expr, (h.op or "="):upper(), d.placeholder(#params));
        end
        statement = statement .. " HAVING " .. table.concat(frags, " AND ");
    end

    if (state.orders and #state.orders > 0) then
        local parts = {};
        for i = 1, #state.orders do
            local o = state.orders[i];
            parts[#parts + 1] = quote_ref(d, o.column) .. " " .. (o.dir or "ASC");
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

--- Scalar aggregate (`SUM`/`AVG`/`MIN`/`MAX`/`COUNT`) over the WHERE-filtered set.
--- The result is aliased `aggregate`. `column` is quoted; pass nil for `*`.
---@param state NormQueryState
---@param func string Aggregate function name (already upper-case).
---@param column? string Column to aggregate (nil -> "*").
---@param d NormDialect
---@return string statement, any[] params
function sql.aggregate(state, func, column, d)
    local params = {};
    local target = column and d.quote(column) or "*";
    local statement = ("SELECT %s(%s) AS %s FROM %s"):format(
        func, target, d.quote("aggregate"), d.quote(state.table));
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

--- Atomic in-place column arithmetic: `UPDATE t SET col = col + ?[, ...] WHERE ...`.
--- Each entry is `{ column = ..., amount = ... }` (a negative amount decrements).
---@param state NormQueryState
---@param columns {column: string, amount: number}[]
---@param d NormDialect
---@return string statement, any[] params
function sql.increment(state, columns, d)
    local params, sets = {}, {};
    for i = 1, #columns do
        local c = columns[i];
        params[#params + 1] = normalize(c.amount);
        local q = d.quote(c.column);
        sets[#sets + 1] = ("%s = %s + %s"):format(q, q, d.placeholder(#params));
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

-- ==========================================================================
-- DDL for migrations (ALTER TABLE / indexes). Statement-only, no params.
-- ==========================================================================

--- `ALTER TABLE t ADD COLUMN <def>`. `column` is a Norm column descriptor (`.name` set).
---@param table_name string
---@param column NormColumn
---@param d NormDialect
---@return string
function sql.add_column(table_name, column, d)
    return ("ALTER TABLE %s ADD COLUMN %s"):format(d.quote(table_name), column_def(column, d));
end

--- `ALTER TABLE t DROP COLUMN c` (MySQL, MariaDB, SQLite >= 3.35, Postgres).
---@param table_name string
---@param name string
---@param d NormDialect
---@return string
function sql.drop_column(table_name, name, d)
    return ("ALTER TABLE %s DROP COLUMN %s"):format(d.quote(table_name), d.quote(name));
end

--- `ALTER TABLE t RENAME COLUMN a TO b` (MySQL 8 / MariaDB 10.5.2+ / SQLite 3.25+ / Postgres).
---@param table_name string
---@param from string
---@param to string
---@param d NormDialect
---@return string
function sql.rename_column(table_name, from, to, d)
    return ("ALTER TABLE %s RENAME COLUMN %s TO %s"):format(
        d.quote(table_name), d.quote(from), d.quote(to));
end

--- `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON table (cols...)`. `if_not_exists`
--- (used by `sync()` for idempotency) is supported by SQLite/MariaDB/Postgres but
--- NOT by stock MySQL 8 — manage those indexes via migrations instead.
---@param table_name string
---@param index_name string
---@param columns string[]
---@param unique boolean
---@param d NormDialect
---@param if_not_exists? boolean
---@return string
function sql.add_index(table_name, index_name, columns, unique, d, if_not_exists)
    local cols = {};
    for i = 1, #columns do cols[i] = d.quote(columns[i]); end
    return ("CREATE %sINDEX %s%s ON %s (%s)"):format(
        unique and "UNIQUE " or "", if_not_exists and "IF NOT EXISTS " or "",
        d.quote(index_name), d.quote(table_name), table.concat(cols, ", "));
end

--- `DROP INDEX`. MySQL needs the table (`DROP INDEX i ON t`); SQLite/Postgres don't.
---@param index_name string
---@param table_name string
---@param d NormDialect
---@return string
function sql.drop_index(index_name, table_name, d)
    if (d.name == "mysql") then
        return ("DROP INDEX %s ON %s"):format(d.quote(index_name), d.quote(table_name));
    end
    return ("DROP INDEX %s"):format(d.quote(index_name));
end

--- `DROP TABLE IF EXISTS t`.
---@param table_name string
---@param d NormDialect
---@return string
function sql.drop_table(table_name, d)
    return ("DROP TABLE IF EXISTS %s"):format(d.quote(table_name));
end

return sql;
