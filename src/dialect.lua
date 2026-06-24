--- SQL dialects: the small syntactic differences between database engines.
--- Adapters expose a dialect so the SQL builder stays engine agnostic.
---@class NormDialects
---@field mysql NormDialect
---@field sqlite NormDialect
local dialect = {};

---@param id string|number
---@return string
local function quote_backtick(id)
    return "`" .. tostring(id):gsub("`", "``") .. "`";
end

---@class NormDialect
---@field name string
---@field quote fun(id: string): string
---@field placeholder fun(index: number): string
---@field autoincrement string
---@field table_suffix string
---@field types table<string, string>

---@type NormDialect
dialect.mysql = {
    name = "mysql",
    quote = quote_backtick,
    placeholder = function() return "?"; end,
    autoincrement = "AUTO_INCREMENT",
    table_suffix = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    types = {
        id = "INT", integer = "INT", bigint = "BIGINT", string = "VARCHAR",
        text = "TEXT", float = "FLOAT", double = "DOUBLE", boolean = "TINYINT(1)",
        datetime = "DATETIME", date = "DATE", json = "JSON",
    },
};

---@type NormDialect
dialect.sqlite = {
    name = "sqlite",
    quote = quote_backtick,
    placeholder = function() return "?"; end,
    autoincrement = "AUTOINCREMENT",
    table_suffix = "",
    types = {
        id = "INTEGER", integer = "INTEGER", bigint = "INTEGER", string = "TEXT",
        text = "TEXT", float = "REAL", double = "REAL", boolean = "INTEGER",
        datetime = "TEXT", date = "TEXT", json = "TEXT",
    },
};

---@param name string
---@return NormDialect
function dialect.get(name)
    local d = dialect[name];
    if (not d) then
        error(("[norm] unknown dialect '%s'"):format(tostring(name)));
    end
    return d;
end

return dialect;
