-- Norm self-test. Run against the built bundle: light-class.lua + dist/norm.lua
-- must already be loaded (global `class` and global `Norm`).
local orm = Norm;
local class = orm.class;

local passed, failed = 0, 0;
local function check(name, cond, extra)
    if (cond) then
        passed = passed + 1;
        print(("  [PASS] %s"):format(name));
    else
        failed = failed + 1;
        print(("  [FAIL] %s %s"):format(name, extra and ("-> " .. tostring(extra)) or ""));
    end
end

-- Mock adapter: records SQL, returns canned results.
local Mock = class.extend("MockAdapter", orm.Adapter);
function Mock:__init(opts)
    orm.Adapter.__init(self, opts);
    self.calls = {};
    self.next_id = 0;
    self.query_result = {};
end
function Mock:raw_query(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "query", sql = q, params = p };
    cb(nil, self.query_result);
end
function Mock:raw_execute(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "execute", sql = q, params = p };
    if (q:match("^%s*[Ii][Nn][Ss][Ee][Rr][Tt]")) then
        self.next_id = self.next_id + 1;
        cb(nil, { affectedRows = 1, insertId = self.next_id });
    else
        cb(nil, { affectedRows = 1 });
    end
end
local function last_sql(mock) return mock.calls[#mock.calls].sql; end

print("== Test group 1: builtin provider (mysql dialect) ==");
local mock = Mock({ dialect = "mysql" });
local db = orm.new({ adapter = mock, promise = orm.promise.builtin() });

local User = db:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 64, nullable = false }),
    email = orm.types.string({ length = 128, unique = true }),
    admin = orm.types.boolean({ default = false }),
    age   = orm.types.integer({ default = 0 }),
});

db:sync();
local create = last_sql(mock);
print("  CREATE: " .. create);
check("create table name", create:find("CREATE TABLE IF NOT EXISTS `users`", 1, true) ~= nil);
check("id is PK auto_increment", create:find("`id` INT PRIMARY KEY AUTO_INCREMENT", 1, true) ~= nil);
check("name VARCHAR(64) NOT NULL", create:find("`name` VARCHAR(64) NOT NULL", 1, true) ~= nil);
check("email UNIQUE", create:find("`email` VARCHAR(128) UNIQUE", 1, true) ~= nil);
check("engine suffix", create:find("ENGINE=InnoDB", 1, true) ~= nil);

local created;
User:create({ name = "John", email = "john@x.io", admin = true }):next(function(u) created = u; end);
print("  INSERT: " .. last_sql(mock));
check("insert omits autoincrement id", last_sql(mock):find("`id`", 1, true) == nil);
check("insert resolved record", created ~= nil);
check("insert assigned insertId", created and created.id == 1, created and created.id);
check("record persisted", created and created.__persisted == true);
check("boolean stored as 1", (function()
    for _, v in ipairs(mock.calls[#mock.calls].params) do if (v == 1) then return true; end end
    return false;
end)());

mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
local found;
User:find(1):next(function(u) found = u; end);
print("  SELECT find: " .. last_sql(mock));
check("find select where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("find select limit 1", last_sql(mock):find("LIMIT 1", 1, true) ~= nil);
check("found record name", found and found.name == "John");
check("boolean parsed to true", found and found.admin == true, found and tostring(found.admin));

mock.query_result = {};
User:where("age", ">", 18):order("name", "DESC"):limit(10):offset(5):all();
local sel = last_sql(mock);
print("  SELECT query: " .. sel);
check("where op >", sel:find("WHERE `age` > ?", 1, true) ~= nil);
check("order by desc", sel:find("ORDER BY `name` DESC", 1, true) ~= nil);
check("limit/offset", sel:find("LIMIT 10 OFFSET 5", 1, true) ~= nil);

mock.query_result = {};
User:query():where({ name = "John" }):where_in("id", { 1, 2, 3 }):all();
local sel2 = last_sql(mock);
print("  SELECT in: " .. sel2);
check("where_in placeholders", sel2:find("`id` IN (?, ?, ?)", 1, true) ~= nil);

mock.query_result = {};
User:query():where_in("id", {}):all();
local sel3 = last_sql(mock);
print("  SELECT empty in: " .. sel3);
check("empty where_in -> constant false predicate",
    sel3:find("1 = 0", 1, true) ~= nil and sel3:find("IN ()", 1, true) == nil, sel3);

found.age = 42;
local saved;
found:save():next(function(u) saved = u; end);
print("  UPDATE: " .. last_sql(mock));
check("update statement", last_sql(mock):find("UPDATE `users` SET", 1, true) ~= nil);
check("update where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("update never sets pk", (function()
    local setpart = last_sql(mock):match("SET (.-) WHERE");
    return setpart ~= nil and setpart:find("`id`", 1, true) == nil;
end)());
check("save resolved record", saved == found);

found:delete();
print("  DELETE: " .. last_sql(mock));
check("delete statement", last_sql(mock):find("DELETE FROM `users` WHERE `id` = ?", 1, true) ~= nil);

mock.query_result = { { count = 7 } };
local n;
User:count():next(function(c) n = c; end);
check("count value", n == 7, n);

print("== Test group 2: sqlite dialect DDL ==");
local mock2 = Mock({ dialect = "sqlite" });
local db2 = orm.new({ adapter = mock2, promise = orm.promise.builtin() });
local Item = db2:define("items", {
    id   = orm.types.id(),
    name = orm.types.string({ length = 32 }),
});
db2:sync();
local createS = last_sql(mock2);
print("  CREATE (sqlite): " .. createS);
check("sqlite integer pk autoincrement", createS:find("`id` INTEGER PRIMARY KEY AUTOINCREMENT", 1, true) ~= nil);
check("sqlite string -> TEXT", createS:find("`name` TEXT", 1, true) ~= nil);
check("sqlite no engine suffix", createS:find("ENGINE", 1, true) == nil);

print("== Test group 3: portability (nanos-style provider with :Then, no :next) ==");
local FakeP = {};
FakeP.__index = FakeP;
local function fake_new(executor)
    local self = setmetatable({ state = "pending", cbs = {} }, FakeP);
    executor(function(v)
        self.value = v; self.state = "ful";
        for i = 1, #self.cbs do self.cbs[i](v); end
    end, function(e) self.err = e; self.state = "rej"; end);
    return self;
end
function FakeP:Then(f)
    if (self.state == "ful") then f(self.value); else self.cbs[#self.cbs + 1] = f; end
    return self;
end
local fakeProvider = {
    name = "fake-nanos",
    new = fake_new,
    resolve = function(v) return fake_new(function(r) r(v); end); end,
    reject = function(e) return fake_new(function(_, j) j(e); end); end,
};

local mock3 = Mock({ dialect = "mysql" });
local db3 = orm.new({ adapter = mock3, promise = fakeProvider });
local Post = db3:define("posts", { id = orm.types.id(), title = orm.types.string({ length = 80 }) });

local ok_sync = false;
db3:sync():Then(function() ok_sync = true; end);
check("sync works with :Then-only provider", ok_sync);

local post;
Post:create({ title = "Hello" }):Then(function(p) post = p; end);
check("create works with :Then-only provider", post ~= nil and post.id == 1, post and post.id);

mock3.query_result = { { id = 1, title = "Hello" } };
local got;
Post:find(1):Then(function(p) got = p; end);
check("find works with :Then-only provider", got ~= nil and got.title == "Hello");

print("== Test group 4: builtin promise chaining (:next / :catch) ==");
local p1ok, caught;
orm.promise.builtin().resolve(10)
    :next(function(v) return v + 5; end)
    :next(function(v) p1ok = (v == 15); end);
check("builtin :next chains transforms", p1ok);

orm.promise.builtin().new(function(_, reject) reject("boom"); end)
    :catch(function(e) caught = e; end);
check("builtin :catch catches", caught == "boom");

print("== Test group 5: duck-typed adapter (no class system) ==");
local plain = {
    _calls = {},
    get_dialect = function(self) return orm.dialect.mysql; end,
    default_provider = function(self) return nil; end,
    raw_query = function(self, q, p, cb) cb(nil, {}); end,
    raw_execute = function(self, q, p, cb) self._calls[#self._calls + 1] = q; cb(nil, { affectedRows = 1, insertId = 9 }); end,
};
local db5 = orm.new({ adapter = plain, promise = orm.promise.builtin() });
local Plain = db5:define("plain", { id = orm.types.id(), v = orm.types.integer() });
local pid;
Plain:create({ v = 1 }):next(function(r) pid = r.id; end);
check("duck-typed adapter works", pid == 9, pid);

print("== Test group 6: builtin promise :await() ==");
-- already-resolved: returns immediately inside a coroutine
coroutine.wrap(function()
    local v = orm.promise.builtin().resolve(42):await();
    check("await on resolved promise", v == 42, v);
end)();

-- pending then settled: await yields, settle resumes the coroutine
local deferred;
local p_pending = orm.promise.builtin().new(function(resolve) deferred = resolve; end);
local awaited;
local co = coroutine.create(function() awaited = p_pending:await(); end);
coroutine.resume(co);          -- blocks at :await()
check("await suspends while pending", awaited == nil);
deferred(99);                  -- settles -> resumes the coroutine
check("await resumes with value", awaited == 99, awaited);

-- rejection: :await() raises
coroutine.wrap(function()
    local ok, err = pcall(function() return orm.promise.builtin().reject("nope"):await(); end);
    check("await raises on rejection", (not ok) and tostring(err):find("nope", 1, true) ~= nil);
end)();

-- end-to-end: await an ORM operation through the builtin provider
coroutine.wrap(function()
    mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
    local u = User:find(1):await();
    check("await an ORM query result", u and u.name == "John", u and u.name);
end)();

-- an error raised AFTER a pending await resumes must be SURFACED, not swallowed
-- (the builtin's _settle resumes the coroutine and reports a failed resume).
do
    local captured, real_print = {}, print;
    print = function(...) captured[#captured + 1] = table.concat({ ... }, " "); end
    local resolve_fn;
    local p = orm.promise.builtin().new(function(res) resolve_fn = res; end);
    local co = coroutine.create(function()
        p:await();
        error("boom-after-await");
    end);
    coroutine.resume(co);  -- suspends at :await()
    resolve_fn(true);      -- resumes -> raises -> must be logged
    print = real_print;
    local found = false;
    for _, line in ipairs(captured) do
        if (line:find("uncaught error after await", 1, true) and line:find("boom-after-await", 1, true)) then
            found = true;
        end
    end
    check("error after await is surfaced (not swallowed)", found, table.concat(captured, " | "));
end

print("== Test group 7: custom promise class (auto-wrapped via from_class) ==");
-- A framework promise with a `Class(executor)` constructor and its OWN :await()
-- (like no-more-rp's). Passing the CLASS directly should auto-wrap it.
local Custom = {};
Custom.__index = Custom;
setmetatable(Custom, { __call = function(cls, executor)
    local p = setmetatable({ state = "pending" }, cls);
    if (type(executor) == "function") then
        executor(
            function(v) if (p.state == "pending") then p.state, p.value = "fulfilled", v; if p.co then coroutine.resume(p.co) end end end,
            function(e) if (p.state == "pending") then p.state, p.value = "rejected", e; if p.co then coroutine.resume(p.co) end end end
        );
    end
    return p;
end });
function Custom:await()
    if (self.state == "pending") then self.co = coroutine.running(); coroutine.yield(); end
    if (self.state == "rejected") then error(self.value); end
    return self.value;
end

local mock7 = Mock({ dialect = "mysql" });
local db7 = orm.new({ adapter = mock7, promise = Custom }); -- pass the CLASS, not a provider
check("auto-wrapped class -> provider name 'class'", db7.provider.name == "class", db7.provider.name);
local U7 = db7:define("u7", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
coroutine.wrap(function()
    local r = U7:create({ name = "Z" }):await();   -- uses the class's own :await()
    check("await on auto-wrapped custom promise", r and r.name == "Z", r and r.name);
end)();

print("== Test group 8: relations (belongs_to / has_many, lazy + eager) ==");
-- A mock that routes SELECTs by table name (returns all rows for that table;
-- the relation attach logic filters by key, so this exercises it faithfully).
local Routed = class.extend("RoutedAdapter", orm.Adapter);
function Routed:__init(opts)
    orm.Adapter.__init(self, opts);
    self.rows = {};       -- table -> rows
    self.queries = {};    -- recorded SELECTs
end
function Routed:raw_query(q, p, cb)
    self.queries[#self.queries + 1] = q;
    local tbl = q:match("FROM `([%w_]+)`");
    local rows = self.rows[tbl] or {};
    -- Honor a simple single-column WHERE (`= ?` or `IN (?, ...)`) via the params,
    -- so lazy loads (which rely on the DB's WHERE) behave realistically.
    local col = q:match("WHERE `([%w_]+)`");
    if (col and #p > 0) then
        local set = {};
        for i = 1, #p do set[p[i]] = true; end
        local filtered = {};
        for i = 1, #rows do if (set[rows[i][col]]) then filtered[#filtered + 1] = rows[i]; end end
        rows = filtered;
    end
    cb(nil, rows);
end
function Routed:raw_execute(q, p, cb)
    self.queries[#self.queries + 1] = q;
    cb(nil, { affectedRows = 1, insertId = 1 });
end

local rmock = Routed({ dialect = "mysql" });
rmock.rows.users = { { id = 1, name = "Alice" }, { id = 2, name = "Bob" } };
rmock.rows.posts = {
    { id = 10, user_id = 1, title = "A1" },
    { id = 11, user_id = 1, title = "A2" },
    { id = 12, user_id = 2, title = "B1" },
};

local rdb = orm.new({ adapter = rmock, promise = orm.promise.builtin() });
local Users = rdb:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 32 }),
    posts = orm.types.hasMany("posts", { key = "user_id" }),
});
local Posts = rdb:define("posts", {
    id      = orm.types.id(),
    title   = orm.types.string({ length = 120 }),
    user_id = orm.types.integer(),
    author  = orm.types.belongsTo("users", { key = "user_id" }),
});

-- relations are separated from columns
check("relation is not a column", Users.columns_by_name.posts == nil and Users.relations.posts ~= nil);
check("create table omits relations", (function()
    rdb:sync();
    for _, q in ipairs(rmock.queries) do
        if (q:find("CREATE TABLE", 1, true) and q:find("users", 1, true)) then
            return q:find("posts", 1, true) == nil;
        end
    end
    return false;
end)());

-- eager belongs_to: posts -> author, batched (1 main + 1 author query)
rmock.queries = {};
local posts;
Posts:query():include("author"):all():next(function(r) posts = r; end);
check("eager belongs_to count", posts and #posts == 3, posts and #posts);
check("eager belongs_to attaches author", posts and posts[1].author and posts[1].author.name == "Alice",
    posts and posts[1].author and posts[1].author.name);
check("eager belongs_to second user", posts and posts[3].author and posts[3].author.name == "Bob");
check("eager belongs_to has no N+1 (2 queries)", #rmock.queries == 2, #rmock.queries);

-- eager has_many: users -> posts, batched (1 main + 1 posts query)
rmock.queries = {};
local users;
Users:query():include("posts"):all():next(function(r) users = r; end);
check("eager has_many groups children", users and #users[1].posts == 2 and #users[2].posts == 1,
    users and (#users[1].posts .. "/" .. #users[2].posts));
check("eager has_many has no N+1 (2 queries)", #rmock.queries == 2, #rmock.queries);

-- lazy belongs_to
local post = Posts:wrap({ id = 10, user_id = 1, title = "A1" });
local author;
post:load("author"):next(function(a) author = a; end);
check("lazy belongs_to loads + caches", author and author.name == "Alice" and post.author == author);

-- lazy has_many
local user = Users:wrap({ id = 1, name = "Alice" });
local ulist;
user:load("posts"):next(function(l) ulist = l; end);
check("lazy has_many loads + caches", ulist and #ulist == 2 and user.posts == ulist, ulist and #ulist);

print("== Test group 9: foreign keys (DDL emission, ordering, options) ==");
-- Collect the latest CREATE TABLE statement per table from a mock's call log.
local function creates_by_table(mock)
    local out = {};
    for _, c in ipairs(mock.calls) do
        local t = c.sql:match("CREATE TABLE IF NOT EXISTS `([%w_]+)`");
        if (t) then out[t] = c.sql; end
    end
    return out;
end
local function define_players_characters(db, action)
    db:define("players", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
    db:define("characters", {
        id        = orm.types.id(),
        player_id = orm.types.integer({ nullable = false }),
        player    = orm.types.belongsTo("players", { key = "player_id", onDelete = action }),
    });
end

-- 9a) mysql + default ("auto"): belongs_to emits a FOREIGN KEY with ON DELETE.
local mfk = Mock({ dialect = "mysql" });
local fdb = orm.new({ adapter = mfk, promise = orm.promise.builtin() });
define_players_characters(fdb, "CASCADE");
fdb:sync();
local mc = creates_by_table(mfk);
check("mysql auto emits FK on belongs_to", mc.characters and mc.characters:find(
    "FOREIGN KEY (`player_id`) REFERENCES `players` (`id`) ON DELETE CASCADE", 1, true) ~= nil, mc.characters);
check("referenced table carries no FK", mc.players and mc.players:find("FOREIGN KEY", 1, true) == nil);

-- 9b) referenced table is created before the referencing table (dependency order).
check("FK dependency order: players before characters", (function()
    local pi, ci;
    for i, c in ipairs(mfk.calls) do
        if (c.sql:find("CREATE TABLE IF NOT EXISTS `players`", 1, true)) then pi = i; end
        if (c.sql:find("CREATE TABLE IF NOT EXISTS `characters`", 1, true)) then ci = i; end
    end
    return pi and ci and pi < ci;
end)());

-- 9c) sqlite + default ("auto"): FK skipped, one-time warning through the logger.
local warns = {};
local sfk = Mock({ dialect = "sqlite" });
local sdb = orm.new({
    adapter = sfk, promise = orm.promise.builtin(),
    logger = function(level, msg) warns[#warns + 1] = tostring(level) .. " " .. tostring(msg); end,
});
define_players_characters(sdb, "CASCADE");
sdb:sync();
sdb:sync(); -- second sync must NOT warn again
local sc = creates_by_table(sfk);
check("sqlite auto skips FK", sc.characters and sc.characters:find("FOREIGN KEY", 1, true) == nil, sc.characters);
check("sqlite auto warns exactly once", (function()
    local n = 0;
    for _, w in ipairs(warns) do if (w:find("foreign keys are not emitted", 1, true)) then n = n + 1; end end
    return n == 1;
end)(), #warns);

-- 9d) foreignKeys=false: never emit, even on mysql.
local nfk = Mock({ dialect = "mysql" });
local ndb = orm.new({ adapter = nfk, promise = orm.promise.builtin(), foreignKeys = false });
define_players_characters(ndb, "CASCADE");
ndb:sync();
local nc = creates_by_table(nfk);
check("foreignKeys=false emits no FK", nc.characters and nc.characters:find("FOREIGN KEY", 1, true) == nil);

-- 9e) foreignKeys=true on sqlite: force inline FK (action normalised to upper-case).
local tfk = Mock({ dialect = "sqlite" });
local tdb = orm.new({ adapter = tfk, promise = orm.promise.builtin(), foreignKeys = true });
tdb:define("players", { id = orm.types.id() });
tdb:define("characters", {
    id = orm.types.id(), player_id = orm.types.integer(),
    player = orm.types.belongsTo("players", { key = "player_id", onDelete = "set null" }),
});
tdb:sync();
local tc = creates_by_table(tfk);
check("foreignKeys=true forces FK on sqlite", tc.characters and tc.characters:find(
    "FOREIGN KEY (`player_id`) REFERENCES `players` (`id`) ON DELETE SET NULL", 1, true) ~= nil, tc.characters);

print("== Test group 10: json provider ((de)serialisation of json columns) ==");
local function params_have(mock, value)
    local params = mock.calls[#mock.calls].params;
    for _, p in ipairs(params) do if (p == value) then return true; end end
    return false;
end
-- A deterministic test provider: encode tags the value, decode wraps the string.
local jp = {
    name = "test",
    encode = function(v) return "ENC:" .. tostring(v.x); end,
    decode = function(s) return { decoded = s }; end,
};

local jmock = Mock({ dialect = "mysql" });
local jdb = orm.new({ adapter = jmock, promise = orm.promise.builtin(), json = jp });
local Doc = jdb:define("docs", { id = orm.types.id(), meta = orm.types.json() });

-- 10a) a Lua table in a json column is encoded on INSERT.
Doc:create({ meta = { x = 7 } });
check("json table encoded on insert", params_have(jmock, "ENC:7"));

-- 10b) a raw string from the driver is decoded on read.
jmock.query_result = { { id = 1, meta = "stored-json" } };
local got;
Doc:find(1):next(function(r) got = r; end);
check("json decoded on read", got and type(got.meta) == "table" and got.meta.decoded == "stored-json",
    got and type(got.meta));

-- 10c) a value already a string is passed through (never double-encoded).
Doc:create({ meta = "already-a-string" });
check("string json value passes through encode", params_have(jmock, "already-a-string"));

-- 10d) bulk update also encodes json columns.
Doc:query():where("id", 1):update({ meta = { x = 9 } });
check("json encoded on bulk update", params_have(jmock, "ENC:9"));

-- 10e) json = false disables (de)serialisation (raw string passthrough).
local rmock2 = Mock({ dialect = "mysql" });
local rdb2 = orm.new({ adapter = rmock2, promise = orm.promise.builtin(), json = false });
local Doc2 = rdb2:define("docs2", { id = orm.types.id(), meta = orm.types.json() });
check("json=false resolves to raw provider", rdb2.json.name == "raw", rdb2.json.name);
rmock2.query_result = { { id = 1, meta = '{"x":1}' } };
local got2;
Doc2:find(1):next(function(r) got2 = r; end);
check("json=false leaves raw string on read", got2 and got2.meta == '{"x":1}', got2 and tostring(got2.meta));

-- 10f) with no host JSON library, auto-detection falls back to the raw provider.
local amock = Mock({ dialect = "mysql" });
local adb = orm.new({ adapter = amock, promise = orm.promise.builtin() });
check("json auto-detect falls back to raw", adb.json.name == "raw", adb.json.name);

-- 10g) the built-in nanos / lua builders wrap their library uniformly.
local fakeJSON = { stringify = function(v) return "S(" .. tostring(v.x) .. ")"; end, parse = function(s) return { p = s }; end };
local np = orm.json.nanos(fakeJSON);
check("json.nanos wraps stringify/parse", np.encode({ x = 3 }) == "S(3)" and np.decode("z").p == "z");
local fakejson = { encode = function(_) return "E"; end, decode = function(_) return "D"; end };
local lp = orm.json.rapidjson(fakejson);
check("json.rapidjson wraps encode/decode", lp.encode({}) == "E" and lp.decode("x") == "D");

do -- scope each group below (Lua caps locals per function at 200)
print("== Test group 11: INSERT ... RETURNING (returning-capable adapter) ==");
-- An adapter that advertises RETURNING support must have its inserts routed
-- through raw_query (the statement returns a row), with the id read from that
-- row — never from raw_execute's insertId (which we deliberately leave nil here).
local RMock = class.extend("ReturningMock", orm.Adapter);
function RMock:__init(opts)
    orm.Adapter.__init(self, opts);
    self.calls = {};
end
function RMock:supports_returning() return true; end
function RMock:raw_query(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "query", sql = q, params = p };
    if (q:find("RETURNING", 1, true)) then cb(nil, { { id = 99 } }); else cb(nil, {}); end
end
function RMock:raw_execute(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "execute", sql = q, params = p };
    cb(nil, { affectedRows = 1 }); -- NO insertId on purpose: id must come from RETURNING
end

local rmock = RMock({ dialect = "sqlite" });
local rdb = orm.new({ adapter = rmock, promise = orm.promise.builtin() });
local RUser = rdb:define("players", { id = orm.types.id(), name = orm.types.string() });

local rcreated;
RUser:create({ name = "Zoe" }):next(function(u) rcreated = u; end);
local rlast = rmock.calls[#rmock.calls];
check("returning: insert routed through raw_query", rlast.kind == "query", rlast.kind);
check("returning: INSERT ... RETURNING `id` emitted", rlast.sql:find("RETURNING `id`", 1, true) ~= nil, rlast.sql);
check("returning: insert omits autoincrement id", rlast.sql:find("(`id`", 1, true) == nil);
check("returning: id read from RETURNING row", rcreated and rcreated.id == 99, rcreated and rcreated.id);
check("returning: record persisted", rcreated and rcreated.__persisted == true);

end do
print("== Test group 12: many-to-many (belongs_to_many via pivot) ==");
-- Reuse the routed mock: it filters SELECTs by table + single-column WHERE, so
-- the pivot query and the target query are exercised faithfully.
local m2m = Routed({ dialect = "mysql" });
m2m.rows.users = { { id = 1, name = "Alice" }, { id = 2, name = "Bob" } };
m2m.rows.roles = { { id = 100, name = "admin" }, { id = 200, name = "mod" }, { id = 300, name = "vip" } };
m2m.rows.role_user = {
    { user_id = 1, role_id = 100 },
    { user_id = 1, role_id = 200 },
    { user_id = 2, role_id = 300 },
};
local mdb = orm.new({ adapter = m2m, promise = orm.promise.builtin() });
-- no options: exercises the default through ("role_user"), key ("user_id") and otherKey ("role_id").
local MUsers = mdb:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 32 }),
    roles = orm.types.belongsToMany("roles"),
});
mdb:define("roles", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });

check("m2m relation is not a column", MUsers.columns_by_name.roles == nil and MUsers.relations.roles ~= nil);

-- eager: users -> roles. Batched: main + pivot + targets = 3 queries (no N+1).
m2m.queries = {};
local musers;
MUsers:query():include("roles"):all():next(function(r) musers = r; end);
check("m2m eager attaches roles", musers and #musers[1].roles == 2 and #musers[2].roles == 1,
    musers and (#musers[1].roles .. "/" .. #musers[2].roles));
check("m2m eager resolved target rows", musers and musers[1].roles[1].name == "admin"
    and musers[2].roles[1].name == "vip", musers and musers[1].roles[1].name);
check("m2m eager no N+1 (3 queries: main + pivot + targets)", #m2m.queries == 3, #m2m.queries);

-- lazy: one parent -> roles array, cached on self[name].
local mu = MUsers:wrap({ id = 1, name = "Alice" });
local mlist;
mu:load("roles"):next(function(l) mlist = l; end);
check("m2m lazy loads + caches", mlist and #mlist == 2 and mu.roles == mlist, mlist and #mlist);

-- parent with no pivot rows -> empty array (not nil).
local mu3 = MUsers:wrap({ id = 99, name = "Nobody" });
local mempty = nil;
local got_empty = false;
mu3:load("roles"):next(function(l) mempty = l; got_empty = true; end);
check("m2m lazy empty array when no links", got_empty and type(mempty) == "table" and #mempty == 0);

end do
print("== Test group 13: timestamps + dirty tracking ==");
local tmk = Mock({ dialect = "sqlite" });
local tdb = orm.new({ adapter = tmk, promise = orm.promise.builtin() });
local Account = tdb:define("accounts", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 32 }),
    coins = orm.types.integer({ default = 0 }),
}, { timestamps = true });

check("timestamps: created_at column added", Account.columns_by_name.created_at ~= nil);
check("timestamps: updated_at column added", Account.columns_by_name.updated_at ~= nil);

-- create -> INSERT stamps both timestamps
local acc;
Account:create({ name = "Tim" }):next(function(u) acc = u; end);
print("  INSERT: " .. last_sql(tmk));
check("timestamps: insert sets created_at + updated_at",
    last_sql(tmk):find("`created_at`", 1, true) ~= nil and last_sql(tmk):find("`updated_at`", 1, true) ~= nil,
    last_sql(tmk));
check("timestamps: created_at populated on record", type(acc.created_at) == "string", acc and acc.created_at);

-- dirty tracking: change ONE column -> UPDATE writes only it (+ updated_at)
local rec = Account:wrap({ id = 5, name = "Old", coins = 10, created_at = "t0", updated_at = "t0" });
rec.coins = 20;
rec:save();
print("  UPDATE: " .. last_sql(tmk));
check("dirty: update writes changed column", last_sql(tmk):find("`coins`", 1, true) ~= nil);
check("dirty: update bumps updated_at", last_sql(tmk):find("`updated_at`", 1, true) ~= nil);
check("dirty: update omits unchanged column", last_sql(tmk):find("`name`", 1, true) == nil, last_sql(tmk));

-- no-op save (nothing changed) -> no query at all, updated_at untouched
local before = #tmk.calls;
local rec2 = Account:wrap({ id = 6, name = "Same", coins = 1, created_at = "t0", updated_at = "t0" });
local same;
rec2:save():next(function(u) same = u; end);
check("dirty: no-op save issues no query", #tmk.calls == before, #tmk.calls - before);
check("dirty: no-op save still resolves the record", same == rec2);
check("dirty: no-op leaves updated_at intact", rec2.updated_at == "t0", rec2.updated_at);

end do
print("== Test group 14: find_or_create / find_or_new / update_or_create ==");
local fc = Routed({ dialect = "mysql" });
fc.rows.players = { { id = 1, account_id = "AAA", name = "Alice" } };
local fdb = orm.new({ adapter = fc, promise = orm.promise.builtin() });
local Player = fdb:define("players", {
    id         = orm.types.id(),
    account_id = orm.types.string({ length = 32 }),
    name       = orm.types.string({ length = 32 }),
});
local function emitted(mock, kind)
    for _, q in ipairs(mock.queries) do if (q:find(kind, 1, true)) then return true; end end
    return false;
end

-- existing -> returns it, no INSERT
fc.queries = {};
local p1;
Player:find_or_create({ account_id = "AAA" }, { name = "ignored" }):next(function(r) p1 = r; end);
check("find_or_create returns existing", p1 and p1.name == "Alice", p1 and p1.name);
check("find_or_create existing issues no INSERT", not emitted(fc, "INSERT"));

-- missing -> INSERT merged attributes + values
fc.queries = {};
local p2;
Player:find_or_create({ account_id = "BBB" }, { name = "Bob" }):next(function(r) p2 = r; end);
check("find_or_create creates when missing", p2 and p2.account_id == "BBB" and p2.name == "Bob", p2 and p2.name);
check("find_or_create persisted the new record", p2 and p2.__persisted == true);
check("find_or_create emitted an INSERT", emitted(fc, "INSERT"));

-- find_or_new: missing -> unsaved build, no INSERT
fc.queries = {};
local p3;
Player:find_or_new({ account_id = "CCC" }, { name = "Cara" }):next(function(r) p3 = r; end);
check("find_or_new builds unsaved when missing", p3 and p3.__persisted == false and p3.name == "Cara");
check("find_or_new issues no INSERT", not emitted(fc, "INSERT"));

-- update_or_create: existing -> UPDATE
fc.queries = {};
local p4;
Player:update_or_create({ account_id = "AAA" }, { name = "Alice2" }):next(function(r) p4 = r; end);
check("update_or_create updates existing", p4 and p4.name == "Alice2", p4 and p4.name);
check("update_or_create emitted an UPDATE", emitted(fc, "UPDATE"));

-- update_or_create: missing -> INSERT
fc.queries = {};
local p5;
Player:update_or_create({ account_id = "DDD" }, { name = "Dave" }):next(function(r) p5 = r; end);
check("update_or_create inserts when missing", p5 and p5.__persisted == true and p5.name == "Dave");
check("update_or_create missing emitted an INSERT", emitted(fc, "INSERT"));

end do
print("== Test group 15: atomic upsert (ON CONFLICT / ON DUPLICATE KEY) ==");
local function upsert_sql_of(mock)
    for _, c in ipairs(mock.calls) do
        if (c.sql:find("ON DUPLICATE KEY UPDATE", 1, true) or c.sql:find("ON CONFLICT", 1, true)) then
            return c.sql;
        end
    end
end

-- MySQL: ON DUPLICATE KEY UPDATE col = VALUES(col)
local um = Mock({ dialect = "mysql" });
um.query_result = { { id = 1, account_id = "X", coins = 5 } };
local Acc = orm.new({ adapter = um, promise = orm.promise.builtin() }):define("accounts", {
    id = orm.types.id(),
    account_id = orm.types.string({ length = 32, unique = true }),
    coins = orm.types.integer({ default = 0 }),
});
local up;
Acc:upsert({ account_id = "X", coins = 5 }, { conflict = { "account_id" } }):next(function(r) up = r; end);
local usql = upsert_sql_of(um);
check("mysql upsert uses ON DUPLICATE KEY UPDATE", usql ~= nil, usql);
check("mysql upsert updates coins via VALUES()", usql and usql:find("`coins` = VALUES(`coins`)", 1, true) ~= nil, usql);
check("mysql upsert does not update the conflict column", usql and usql:find("`account_id` = VALUES", 1, true) == nil, usql);
check("upsert returns the read-back record", up and up.account_id == "X", up and up.account_id);

-- SQLite: ON CONFLICT (target) DO UPDATE SET col = excluded.col
local us = Mock({ dialect = "sqlite" });
us.query_result = { { id = 1, account_id = "X", coins = 5 } };
local Acc2 = orm.new({ adapter = us, promise = orm.promise.builtin() }):define("accounts", {
    id = orm.types.id(),
    account_id = orm.types.string({ length = 32, unique = true }),
    coins = orm.types.integer({ default = 0 }),
});
Acc2:upsert({ account_id = "X", coins = 5 }, { conflict = { "account_id" } });
local ssql = upsert_sql_of(us);
check("sqlite upsert uses ON CONFLICT (...) DO UPDATE",
    ssql and ssql:find("ON CONFLICT (`account_id`) DO UPDATE SET", 1, true) ~= nil, ssql);
check("sqlite upsert sets coins = excluded.coins",
    ssql and ssql:find("`coins` = excluded.`coins`", 1, true) ~= nil, ssql);

-- timestamps: insert stamps both; conflict-update bumps updated_at, preserves created_at
local ut = Mock({ dialect = "sqlite" });
ut.query_result = { { id = 1, account_id = "X" } };
local Acc3 = orm.new({ adapter = ut, promise = orm.promise.builtin() }):define("accounts", {
    id = orm.types.id(),
    account_id = orm.types.string({ length = 32, unique = true }),
}, { timestamps = true });
Acc3:upsert({ account_id = "X" }, { conflict = { "account_id" } });
local tsql = upsert_sql_of(ut);
check("upsert inserts created_at + updated_at",
    tsql and tsql:find("`created_at`", 1, true) ~= nil and tsql:find("`updated_at`", 1, true) ~= nil, tsql);
check("upsert update bumps updated_at, preserves created_at",
    tsql and tsql:find("`updated_at` = excluded.`updated_at`", 1, true) ~= nil
        and tsql:find("`created_at` = excluded.`created_at`", 1, true) == nil, tsql);

end do
print("== Test group 16: aggregations (scalar + grouped) ==");
local am = Mock({ dialect = "mysql" });
local Agg = orm.new({ adapter = am, promise = orm.promise.builtin() }):define("players", {
    id      = orm.types.id(),
    faction = orm.types.string({ length = 16 }),
    coins   = orm.types.integer({ default = 0 }),
    score   = orm.types.integer({ default = 0 }),
});

-- scalar SUM over a WHERE filter
am.query_result = { { aggregate = 1500 } };
local total;
Agg:where("faction", "red"):sum("coins"):next(function(v) total = v; end);
check("sum builds SUM(col) AS aggregate", last_sql(am):find("SELECT SUM(`coins`) AS `aggregate`", 1, true) ~= nil, last_sql(am));
check("sum applies WHERE", last_sql(am):find("WHERE `faction` = ?", 1, true) ~= nil, last_sql(am));
check("sum resolves a number", total == 1500, total);

-- MAX returns the raw value
am.query_result = { { aggregate = 99 } };
local top;
Agg:max("score"):next(function(v) top = v; end);
check("max builds MAX(col)", last_sql(am):find("SELECT MAX(`score`) AS `aggregate`", 1, true) ~= nil, last_sql(am));
check("max resolves the value", top == 99, top);

-- AVG via the model-level delegator
am.query_result = { { aggregate = 42 } };
local avg;
Agg:avg("coins"):next(function(v) avg = v; end);
check("avg via model delegator", last_sql(am):find("SELECT AVG(`coins`)", 1, true) ~= nil and avg == 42, avg);

-- grouped aggregate: select_raw + group_by + having + rows()
am.query_result = { { faction = "red", n = 12 }, { faction = "blue", n = 11 } };
local stats;
Agg:select_raw("`faction`, COUNT(*) AS n"):group_by("faction"):having("COUNT(*)", ">", 10):rows():next(function(r) stats = r; end);
local gsql = last_sql(am);
print("  GROUPED: " .. gsql);
check("select_raw kept verbatim", gsql:find("SELECT `faction`, COUNT(*) AS n FROM", 1, true) ~= nil, gsql);
check("group_by emits GROUP BY", gsql:find("GROUP BY `faction`", 1, true) ~= nil, gsql);
check("having emits HAVING with a bound param", gsql:find("HAVING COUNT(*) > ?", 1, true) ~= nil, gsql);
check("rows() returns raw rows (no wrapping)", stats and #stats == 2 and stats[1].faction == "red", stats and #stats);

end do
print("== Test group 17: migrations ==");
local function find_sql(mock, needle)
    for _, c in ipairs(mock.calls) do if (c.sql:find(needle, 1, true)) then return c.sql; end end
end

-- fresh DB: nothing applied -> both migrations run, in order, and get recorded
local mm = Mock({ dialect = "sqlite" });
local mdb = orm.new({ adapter = mm, promise = orm.promise.builtin() });
mm.query_result = {};
local applied;
mdb:migrate({
    { id = "001_add_last_seen", up = function(m)
        m:add_column("players", "last_seen", orm.types.datetime());
        m:add_index("players", "idx_acc", { "account_id" }, { unique = true });
    end },
    { id = "002_drop_temp", up = function(m) m:drop_column("players", "temp"); end },
}):next(function(list) applied = list; end);

check("migrate creates the tracking table", find_sql(mm, "CREATE TABLE IF NOT EXISTS `norm_migrations`") ~= nil);
check("migrate string PK is TEXT on sqlite (not forced INTEGER)",
    (function() local s = find_sql(mm, "norm_migrations"); return s and s:find("`id` TEXT PRIMARY KEY", 1, true) ~= nil, s; end)());
check("migrate emits ADD COLUMN", find_sql(mm, "ALTER TABLE `players` ADD COLUMN `last_seen`") ~= nil);
check("migrate emits CREATE UNIQUE INDEX", find_sql(mm, "CREATE UNIQUE INDEX `idx_acc` ON `players` (`account_id`)") ~= nil);
check("migrate emits DROP COLUMN", find_sql(mm, "ALTER TABLE `players` DROP COLUMN `temp`") ~= nil);
check("migrate records applied ids", find_sql(mm, "INSERT INTO `norm_migrations`") ~= nil);
check("migrate returns the applied list", applied and #applied == 2, applied and #applied);

-- idempotency: 001 already applied -> only 002 runs
local mm2 = Mock({ dialect = "sqlite" });
local mdb2 = orm.new({ adapter = mm2, promise = orm.promise.builtin() });
mm2.query_result = { { id = "001_add_last_seen" } };
local applied2;
mdb2:migrate({
    { id = "001_add_last_seen", up = function(m) m:add_column("players", "x", orm.types.integer()); end },
    { id = "002_drop_temp", up = function(m) m:drop_column("players", "temp"); end },
}):next(function(list) applied2 = list; end);
check("migrate skips already-applied", applied2 and #applied2 == 1 and applied2[1] == "002_drop_temp", applied2 and applied2[1]);
check("migrate does not re-run an applied migration", find_sql(mm2, "ADD COLUMN `x`") == nil);

-- drop_index dialect difference
local mmx = Mock({ dialect = "mysql" });
local mdbx = orm.new({ adapter = mmx, promise = orm.promise.builtin() });
mmx.query_result = {};
mdbx:migrate({ { id = "di", up = function(m) m:drop_index("idx_acc", "players"); end } });
check("mysql drop_index targets the table", find_sql(mmx, "DROP INDEX `idx_acc` ON `players`") ~= nil);

local mms = Mock({ dialect = "sqlite" });
local mdbs = orm.new({ adapter = mms, promise = orm.promise.builtin() });
mms.query_result = {};
mdbs:migrate({ { id = "di", up = function(m) m:drop_index("idx_acc", "players"); end } });
check("sqlite drop_index omits ON table",
    find_sql(mms, "DROP INDEX `idx_acc`") ~= nil and find_sql(mms, "DROP INDEX `idx_acc` ON") == nil);

end do
print("== Test group 18: m2m attach / detach / sync_pivot ==");
local pm = Routed({ dialect = "mysql" });
pm.rows.role_user = { { user_id = 1, role_id = 100 }, { user_id = 1, role_id = 200 } };
local pdb = orm.new({ adapter = pm, promise = orm.promise.builtin() });
local PUser = pdb:define("users", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }),
    roles = orm.types.belongsToMany("roles"),
});
pdb:define("roles", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
local u = PUser:wrap({ id = 1, name = "Alice" });
local function count_matching(mock, needle)
    local n = 0;
    for _, q in ipairs(mock.queries) do if (q:find(needle, 1, true)) then n = n + 1; end end
    return n;
end
local function any_matching(mock, ...)
    local needles = { ... };
    for _, q in ipairs(mock.queries) do
        local all = true;
        for i = 1, #needles do if (q:find(needles[i], 1, true) == nil) then all = false; break; end end
        if (all) then return true; end
    end
    return false;
end

-- attach two ids -> one pivot insert each
pm.queries = {};
local attached;
u:attach("roles", { 300, 400 }):next(function(n) attached = n; end);
check("attach inserts one pivot row per id", count_matching(pm, "INSERT INTO `role_user`") == 2, count_matching(pm, "INSERT INTO `role_user`"));
check("attach returns the count", attached == 2, attached);
check("attach pivot row carries both keys", any_matching(pm, "INSERT INTO `role_user`", "`role_id`", "`user_id`"));

-- detach specific -> one DELETE with role_id IN
pm.queries = {};
u:detach("roles", { 100 });
check("detach emits DELETE with user_id = ? AND role_id IN",
    any_matching(pm, "DELETE FROM `role_user`", "`user_id` = ?", "`role_id` IN"));

-- detach all -> DELETE by user_id only (no IN)
pm.queries = {};
u:detach("roles");
check("detach-all emits DELETE by user_id only", (function()
    for _, q in ipairs(pm.queries) do
        if (q:find("DELETE FROM `role_user`", 1, true) and q:find("IN", 1, true) == nil) then return true; end
    end
    return false;
end)());

-- sync_pivot: current {100,200}, desired {200,300} -> attach 300, detach 100
pm.queries = {};
local synced;
u:sync_pivot("roles", { 200, 300 }):next(function(r) synced = r; end);
check("sync_pivot computes attach/detach counts", synced and synced.attached == 1 and synced.detached == 1,
    synced and (synced.attached .. "/" .. synced.detached));
check("sync_pivot deletes the removed id", count_matching(pm, "DELETE FROM `role_user`") == 1);
check("sync_pivot inserts the new id", count_matching(pm, "INSERT INTO `role_user`") == 1);

end do
print("== Test group 19: joins (filter/sort by a related column) ==");
local jm = Mock({ dialect = "mysql" });
jm.query_result = { { id = 10, user_id = 1, title = "A" } };
local jdb = orm.new({ adapter = jm, promise = orm.promise.builtin() });
local Post = jdb:define("posts", {
    id = orm.types.id(), user_id = orm.types.integer(), title = orm.types.string({ length = 120 }),
});

-- inner join + filter by a joined column + project main.* so :all() still wraps
local posts;
Post:join("users", "users.id", "=", "posts.user_id")
    :where("users.admin", true)
    :select_raw("`posts`.*")
    :all():next(function(r) posts = r; end);
local jsql = last_sql(jm);
print("  JOIN: " .. jsql);
check("inner join clause emitted",
    jsql:find("INNER JOIN `users` ON `users`.`id` = `posts`.`user_id`", 1, true) ~= nil, jsql);
check("where on qualified column", jsql:find("WHERE `users`.`admin` = ?", 1, true) ~= nil, jsql);
check("select_raw projects the main table", jsql:find("SELECT `posts`.* FROM `posts`", 1, true) ~= nil, jsql);
check("joined rows still wrap into records", posts and posts[1] and posts[1].title == "A", posts and posts[1] and posts[1].title);

-- left join, 3-arg form (default `=`), order by a joined column
jm.query_result = {};
Post:left_join("users", "users.id", "posts.user_id"):order("users.name", "DESC"):all();
local lsql = last_sql(jm);
print("  LEFT: " .. lsql);
check("left join clause emitted",
    lsql:find("LEFT JOIN `users` ON `users`.`id` = `posts`.`user_id`", 1, true) ~= nil, lsql);
check("order by a qualified column", lsql:find("ORDER BY `users`.`name` DESC", 1, true) ~= nil, lsql);

end do
print("== Test group 20: queue_until_ready ==");
-- default (off): ready immediately, queries run at once
local nm = Mock({ dialect = "sqlite" });
local ndb = orm.new({ adapter = nm, promise = orm.promise.builtin() });
check("ready immediately when queueing is off", ndb:is_ready() == true);
local NUser = ndb:define("u", { id = orm.types.id() });
nm.query_result = { { id = 5 } };
nm.calls = {};
local got;
NUser:find(5):next(function(r) got = r; end);
check("query runs immediately when queueing is off", #nm.calls == 1 and got and got.id == 5, got and got.id);

-- on: hold until sync
local qm = Mock({ dialect = "sqlite" });
local qdb = orm.new({ adapter = qm, promise = orm.promise.builtin(), queue_until_ready = true });
local QUser = qdb:define("users", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
check("not ready before sync (queueing on)", qdb:is_ready() == false);

qm.query_result = { { id = 1, name = "Zoe" } };
qm.calls = {};
local found, resolved = nil, false;
QUser:find(1):next(function(u) found = u; resolved = true; end);
check("query is held (no adapter call before ready)", #qm.calls == 0, #qm.calls);
check("queued query has not resolved yet", resolved == false);

qdb:sync();
check("ready after sync", qdb:is_ready() == true);
check("queued query ran + resolved after sync", resolved == true and found and found.name == "Zoe", found and found.name);

-- migrate() does NOT mark ready (only sync creates all model tables); it still
-- runs (bypassing the queue), but readiness stays until a sync().
local gm = Mock({ dialect = "sqlite" });
local gdb = orm.new({ adapter = gm, promise = orm.promise.builtin(), queue_until_ready = true });
gm.query_result = {};
local migrated;
check("not ready before migrate", gdb:is_ready() == false);
gdb:migrate({ { id = "init", up = function(m) m:add_column("t", "c", orm.types.integer()); end } })
    :next(function(list) migrated = list; end);
check("migrate ran despite not-ready (bypasses the queue)", migrated and migrated[1] == "init", migrated and migrated[1]);
check("migrate does NOT mark ready", gdb:is_ready() == false);
gdb:sync();
check("sync marks ready after migrate", gdb:is_ready() == true);

end do
print("== Test group 21: nested includes (include \"posts.comments\") ==");
local nm = Routed({ dialect = "mysql" });
nm.rows.users = { { id = 1, name = "A" }, { id = 2, name = "B" } };
nm.rows.posts = { { id = 10, user_id = 1 }, { id = 11, user_id = 1 }, { id = 12, user_id = 2 } };
nm.rows.comments = { { id = 100, post_id = 10 }, { id = 101, post_id = 10 }, { id = 102, post_id = 12 } };
local ndb = orm.new({ adapter = nm, promise = orm.promise.builtin() });
local NUser = ndb:define("users", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }),
    posts = orm.types.hasMany("posts", { key = "user_id" }),
});
ndb:define("posts", {
    id = orm.types.id(), user_id = orm.types.integer(),
    comments = orm.types.hasMany("comments", { key = "post_id" }),
});
ndb:define("comments", { id = orm.types.id(), post_id = orm.types.integer() });

nm.queries = {};
local nusers;
NUser:query():include("posts.comments"):all():next(function(r) nusers = r; end);
check("nested: users carry their posts", nusers and #nusers[1].posts == 2 and #nusers[2].posts == 1,
    nusers and (#nusers[1].posts .. "/" .. #nusers[2].posts));
check("nested: posts carry their comments", nusers and nusers[1].posts[1] and #nusers[1].posts[1].comments == 2,
    nusers and nusers[1].posts[1] and #nusers[1].posts[1].comments);
check("nested: second branch loaded too", nusers and nusers[2].posts[1] and #nusers[2].posts[1].comments == 1,
    nusers and nusers[2].posts[1] and #nusers[2].posts[1].comments);
check("nested: no N+1 (3 queries: users + posts + comments)", #nm.queries == 3, #nm.queries);

end do
print("== Test group 22: omit (select all columns but some) ==");
local om = Mock({ dialect = "mysql" });
om.query_result = { { id = 1, name = "Al", email = "a@b.c" } };
local Odb = orm.new({ adapter = om, promise = orm.promise.builtin() });
local OUser = Odb:define("users", {
    id       = orm.types.id(),
    name     = orm.types.string({ length = 32 }),
    email    = orm.types.string({ length = 64 }),
    password = orm.types.string({ length = 64 }),
});
local omitted;
OUser:omit("password"):first():next(function(u) omitted = u; end);
local osql = last_sql(om);
print("  OMIT: " .. osql);
check("omit keeps the other columns",
    osql:find("`id`", 1, true) and osql:find("`name`", 1, true) and osql:find("`email`", 1, true) ~= nil, osql);
check("omit excludes the listed column", osql:find("`password`", 1, true) == nil, osql);
check("omit is not SELECT *", osql:find("SELECT *", 1, true) == nil, osql);
check("omitted column is absent on the record", omitted and omitted.password == nil and omitted.name == "Al",
    omitted and omitted.name);

end do
print("== Test group 23: include with options (where / order / limit per parent) ==");
local im = Routed({ dialect = "mysql" });
im.rows.users = { { id = 1, name = "A" }, { id = 2, name = "B" } };
im.rows.posts = {
    { id = 10, user_id = 1, published = 1, created_at = "2026-01-03" },
    { id = 11, user_id = 1, published = 1, created_at = "2026-01-02" },
    { id = 12, user_id = 1, published = 1, created_at = "2026-01-01" },
    { id = 13, user_id = 2, published = 1, created_at = "2026-01-05" },
};
im.rows.comments = { { id = 100, post_id = 10 }, { id = 101, post_id = 11 } };
local idb = orm.new({ adapter = im, promise = orm.promise.builtin() });
local IUser = idb:define("users", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }),
    posts = orm.types.hasMany("posts", { key = "user_id" }),
});
idb:define("posts", {
    id = orm.types.id(), user_id = orm.types.integer(),
    published = orm.types.boolean(), created_at = orm.types.datetime(),
    comments = orm.types.hasMany("comments", { key = "post_id" }),
});
idb:define("comments", { id = orm.types.id(), post_id = orm.types.integer() });

-- options: where + order + per-parent limit
im.queries = {};
local iusers;
IUser:query():include("posts", function(q)
    q:where("published", true):order("created_at", "DESC"):limit(2);
end):all():next(function(r) iusers = r; end);
local posts_sql;
for _, q in ipairs(im.queries) do if (q:find("FROM `posts`", 1, true)) then posts_sql = q; end end
print("  POSTS: " .. tostring(posts_sql));
check("include options: WHERE merged onto the relation", posts_sql and posts_sql:find("`published` = ?", 1, true) ~= nil, posts_sql);
check("include options: IN still present (batched)", posts_sql and posts_sql:find("`user_id` IN", 1, true) ~= nil, posts_sql);
check("include options: ORDER BY emitted", posts_sql and posts_sql:find("ORDER BY `created_at` DESC", 1, true) ~= nil, posts_sql);
check("include options: limit applied PER PARENT", iusers and #iusers[1].posts == 2, iusers and #iusers[1].posts);
check("include options: other parent unaffected", iusers and #iusers[2].posts == 1, iusers and #iusers[2].posts);
check("include options: still 2 queries (no N+1)", #im.queries == 2, #im.queries);

-- nested configurator: posts -> comments
im.queries = {};
local iu2;
IUser:query():include("posts", function(q)
    q:include("comments", function(c) c:order("id", "ASC"); end);
end):all():next(function(r) iu2 = r; end);
check("nested configurator loads the deeper relation",
    iu2 and iu2[1].posts[1] and iu2[1].posts[1].comments ~= nil);
check("nested configurator still batched (3 queries)", #im.queries == 3, #im.queries);

end do
print("== Test group 24: soft deletes ==");
local sm = Mock({ dialect = "sqlite" });
local sdb = orm.new({ adapter = sm, promise = orm.promise.builtin() });
local SPost = sdb:define("posts", {
    id = orm.types.id(), title = orm.types.string({ length = 64 }),
}, { soft_deletes = true });

check("soft_deletes adds the deleted_at column", SPost.columns_by_name.deleted_at ~= nil);
check("model records the soft-delete column", SPost.soft_deletes == "deleted_at");

-- default queries exclude trashed
sm.query_result = {};
SPost:all();
check("default select excludes trashed", last_sql(sm):find("`deleted_at` IS NULL", 1, true) ~= nil, last_sql(sm));
SPost:count();
check("count excludes trashed", last_sql(sm):find("`deleted_at` IS NULL", 1, true) ~= nil, last_sql(sm));

-- scopes
SPost:with_trashed():all();
check("with_trashed drops the filter", last_sql(sm):find("deleted_at", 1, true) == nil, last_sql(sm));
SPost:only_trashed():all();
check("only_trashed filters IS NOT NULL", last_sql(sm):find("`deleted_at` IS NOT NULL", 1, true) ~= nil, last_sql(sm));

-- record:delete() soft-deletes (UPDATE, not DELETE); trashed() reflects it
sm.query_result = { { id = 1, title = "Hi" } };
local spost;
SPost:find(1):next(function(r) spost = r; end);
check("find excludes trashed too", last_sql(sm):find("`deleted_at` IS NULL", 1, true) ~= nil, last_sql(sm));
spost:delete();
check("record delete soft-deletes (UPDATE deleted_at)", last_sql(sm):find("UPDATE `posts` SET `deleted_at`", 1, true) ~= nil, last_sql(sm));
check("record is now trashed", spost:trashed() == true);

-- restore -> deleted_at = NULL
spost:restore();
check("restore clears deleted_at", last_sql(sm):find("SET `deleted_at` = NULL", 1, true) ~= nil, last_sql(sm));
check("record no longer trashed", spost:trashed() == false);

-- force_delete -> physical DELETE
spost:force_delete();
check("force_delete issues a real DELETE", last_sql(sm):find("DELETE FROM `posts`", 1, true) ~= nil, last_sql(sm));

-- the column lands in CREATE TABLE
sdb:sync();
local screate;
for _, c in ipairs(sm.calls) do if (c.sql:find("CREATE TABLE", 1, true)) then screate = c.sql; end end
check("sync creates the deleted_at column", screate and screate:find("`deleted_at`", 1, true) ~= nil, screate);

end do
print("== Test group 25: transactions ==");
-- a transaction-capable adapter (records what it's asked to do)
local TxMock = class.extend("TxMock", orm.Adapter);
function TxMock:__init(opts) orm.Adapter.__init(self, opts); self.log = {}; self.qr = {}; end
function TxMock:supports_transactions() return true; end
function TxMock:raw_query(q, p, cb) self.log[#self.log + 1] = "POOL_Q"; cb(nil, self.qr); end
function TxMock:raw_execute(q, p, cb) self.log[#self.log + 1] = "POOL_E"; cb(nil, { affectedRows = 1, insertId = 1 }); end
-- scoped contract: open, run body with sync tx fns, commit/rollback on its return.
function TxMock:transaction(body, finish)
    self.log[#self.log + 1] = "BEGIN";
    local tx_query = function(q, p, cb) self.log[#self.log + 1] = "TX_Q"; cb(nil, self.qr); end;
    local tx_execute = function(q, p, cb) self.log[#self.log + 1] = "TX_E"; cb(nil, { affectedRows = 1, insertId = 1 }); end;
    local commit = body(tx_query, tx_execute);
    if (commit) then self.log[#self.log + 1] = "COMMIT"; finish(nil);
    else self.log[#self.log + 1] = "ROLLBACK"; finish("rolled back"); end
end
local function log_has(mock, needle)
    for _, e in ipairs(mock.log) do if (e == needle) then return true; end end
    return false;
end

local tmk = TxMock({ dialect = "sqlite" });
local txdb = orm.new({ adapter = tmk, promise = orm.promise.builtin() });
local TU = txdb:define("users", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });

-- commit path: ops route through the transaction
tmk.log = {};
local result;
coroutine.wrap(function()
    result = txdb:transaction(function()
        TU:create({ name = "A" }):await();
        TU:create({ name = "B" }):await();
        return "ok";
    end):await();
end)();
check("transaction begins", log_has(tmk, "BEGIN"));
check("ops route through the transaction (txn_execute)", (function()
    local n = 0; for _, e in ipairs(tmk.log) do if (e == "TX_E") then n = n + 1; end end return n == 2;
end)());
check("ops did NOT use the pool", not log_has(tmk, "POOL_E"));
check("transaction commits on success", tmk.log[#tmk.log] == "COMMIT", tmk.log[#tmk.log]);
check("transaction resolves fn's return value", result == "ok", result);
check("active transaction cleared afterwards", txdb._tx == nil);

-- rollback path: fn raises
tmk.log = {};
local terr;
coroutine.wrap(function()
    local ok, e = pcall(function()
        txdb:transaction(function()
            TU:create({ name = "C" }):await();
            error("boom");
        end):await();
    end);
    terr = (not ok) and tostring(e) or nil;
end)();
check("transaction rolls back on error", log_has(tmk, "ROLLBACK") and not log_has(tmk, "COMMIT"));
check("transaction propagates the error", terr and terr:find("boom", 1, true) ~= nil, terr);
check("active transaction cleared after rollback", txdb._tx == nil);

-- unsupported adapter -> transaction() THROWS
local plain = Mock({ dialect = "sqlite" });
local pdbx = orm.new({ adapter = plain, promise = orm.promise.builtin() });
check("supports_transactions reflects the adapter", pdbx:supports_transactions() == false);
check("transaction throws on an unsupported adapter",
    select(1, pcall(function() pdbx:transaction(function() end) end)) == false);
end do
print("== Test group 26: lifecycle hooks ==");
local hm = Mock({ dialect = "sqlite" });
local hdb = orm.new({ adapter = hm, promise = orm.promise.builtin() });
local events = {};
local function rec(name) return function() events[#events + 1] = name; end end
local Player = hdb:define("players", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }), slug = orm.types.string({ length = 32 }),
});
Player:before_save(function(p) events[#events + 1] = "before_save"; if (not p.slug) then p.slug = "auto-" .. tostring(p.name); end end);
Player:before_create(rec("before_create"));
Player:after_create(rec("after_create"));
Player:before_update(rec("before_update"));
Player:after_update(rec("after_update"));
Player:after_save(rec("after_save"));
Player:before_delete(rec("before_delete"));
Player:after_delete(rec("after_delete"));
Player:after_find(rec("after_find"));

-- create fires save+create hooks in order; before_save mutation is persisted
events = {};
local created;
Player:create({ name = "Zoe" }):next(function(r) created = r; end);
check("create fires hooks in order",
    table.concat(events, ",") == "before_save,before_create,after_create,after_save", table.concat(events, ","));
check("before_save mutation persisted on the record", created and created.slug == "auto-Zoe", created and created.slug);
check("before_save mutation reached the INSERT", (function()
    for _, c in ipairs(hm.calls) do
        if (c.sql:find("INSERT", 1, true)) then
            for _, v in ipairs(c.params) do if (v == "auto-Zoe") then return true; end end
        end
    end
    return false;
end)());

-- find fires after_find (one wrapped row)
events = {};
hm.query_result = { { id = 1, name = "Max", slug = "s" } };
local found;
Player:find(1):next(function(r) found = r; end);
check("find fires after_find", table.concat(events, ",") == "after_find", table.concat(events, ","));

-- update fires save+update hooks
events = {};
found.name = "Max2";
found:save();
check("update fires save+update hooks",
    table.concat(events, ",") == "before_save,before_update,after_update,after_save", table.concat(events, ","));

-- delete fires delete hooks
events = {};
found:delete();
check("delete fires delete hooks", table.concat(events, ",") == "before_delete,after_delete", table.concat(events, ","));

-- a throwing before hook cancels the operation (promise rejects, no write)
local gm = Mock({ dialect = "sqlite" });
local gdb = orm.new({ adapter = gm, promise = orm.promise.builtin() });
local Guarded = gdb:define("items", { id = orm.types.id(), qty = orm.types.integer() });
Guarded:before_save(function(r) if (r.qty and r.qty < 0) then error("qty must be >= 0"); end end);
local rejected = false;
Guarded:create({ qty = -5 }):next(nil, function() rejected = true; end);
check("before hook abort rejects the promise", rejected == true);
check("aborted create issued no INSERT", (function()
    for _, c in ipairs(gm.calls) do if (c.sql:find("INSERT", 1, true)) then return false; end end
    return true;
end)());

-- define-time hooks register
local ddb = orm.new({ adapter = Mock({ dialect = "sqlite" }), promise = orm.promise.builtin() });
local dhits = 0;
local D = ddb:define("d", { id = orm.types.id() }, { hooks = { after_create = function() dhits = dhits + 1; end } });
D:create({}):next(function() end);
check("define-time hook fires", dhits == 1, dhits);

-- hook-less models stay flagged off
local Plain = orm.new({ adapter = Mock({ dialect = "sqlite" }), promise = orm.promise.builtin() }):define("plain", { id = orm.types.id() });
check("hook-less model has _has_hooks false", Plain._has_hooks == false);
end do
print("== Test group 27: increment / decrement ==");
local cm = Mock({ dialect = "sqlite" });
local cdb = orm.new({ adapter = cm, promise = orm.promise.builtin() });
local Acc = cdb:define("accounts", { id = orm.types.id(), coins = orm.types.integer({ default = 0 }) });

-- builder increment: SET col = col + ? over the WHERE
cm.query_result = {};
Acc:where("id", 1):increment("coins", 50);
local isql = last_sql(cm);
print("  INC: " .. isql);
check("increment builds SET col = col + ?", isql:find("UPDATE `accounts` SET `coins` = `coins` + ?", 1, true) ~= nil, isql);
check("increment keeps the WHERE", isql:find("WHERE `id` = ?", 1, true) ~= nil, isql);
check("increment binds amount then where", (function()
    local p = cm.calls[#cm.calls].params;
    return p[1] == 50 and p[2] == 1;
end)());

-- builder decrement: negative amount
Acc:where("id", 1):decrement("coins", 10);
check("decrement binds a negative amount", cm.calls[#cm.calls].params[1] == -10, cm.calls[#cm.calls].params[1]);

-- default amount = 1
Acc:where("id", 1):increment("coins");
check("increment defaults to 1", cm.calls[#cm.calls].params[1] == 1);

-- record increment: targets the PK AND updates the in-memory value
local rec = Acc:wrap({ id = 7, coins = 100 });
rec:increment("coins", 25);
check("record increment targets the pk", last_sql(cm):find("WHERE `id` = ?", 1, true) ~= nil, last_sql(cm));
check("record increment updates memory", rec.coins == 125, rec.coins);
rec:decrement("coins", 5);
check("record decrement updates memory", rec.coins == 120, rec.coins);
end do
print("== Test group 28: where_has / where_doesnt_have / with_count ==");
local wm = Mock({ dialect = "mysql" });
local wdb = orm.new({ adapter = wm, promise = orm.promise.builtin() });
local WUser = wdb:define("users", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }),
    posts = orm.types.hasMany("posts", { key = "user_id" }),
});
wdb:define("posts", {
    id = orm.types.id(), user_id = orm.types.integer(), published = orm.types.boolean(),
});

-- where_has -> EXISTS correlated subquery
wm.query_result = {};
WUser:where_has("posts"):all();
local hsql = last_sql(wm);
print("  HAS: " .. hsql);
check("where_has emits EXISTS", hsql:find("EXISTS (SELECT 1 FROM `posts`", 1, true) ~= nil, hsql);
check("where_has correlates target.fk to parent.pk",
    hsql:find("`posts`.`user_id` = `users`.`id`", 1, true) ~= nil, hsql);

-- where_has with a condition on the relation
wm.query_result = {};
WUser:where_has("posts", function(q) q:where("published", true) end):all();
local hsql2 = last_sql(wm);
check("where_has merges relation conditions", hsql2:find("`published` = ?", 1, true) ~= nil, hsql2);
check("where_has binds the relation param", wm.calls[#wm.calls].params[1] == 1, wm.calls[#wm.calls].params[1]);

-- where_doesnt_have -> NOT EXISTS
wm.query_result = {};
WUser:where_doesnt_have("posts"):all();
check("where_doesnt_have emits NOT EXISTS", last_sql(wm):find("NOT EXISTS (SELECT 1 FROM `posts`", 1, true) ~= nil, last_sql(wm));

-- with_count -> correlated COUNT(*) AS posts_count, attached to records
wm.query_result = { { id = 1, name = "A", posts_count = 3 } };
local wusers;
WUser:with_count("posts"):all():next(function(r) wusers = r end);
local csql = last_sql(wm);
print("  COUNT: " .. csql);
check("with_count selects COUNT(*) AS posts_count",
    csql:find("(SELECT COUNT(*) FROM `posts`", 1, true) ~= nil and csql:find("AS `posts_count`", 1, true) ~= nil, csql);
check("with_count keeps the main columns (*)", csql:find("SELECT *,", 1, true) ~= nil, csql);
check("with_count attaches the count to the record", wusers and wusers[1].posts_count == 3, wusers and wusers[1] and wusers[1].posts_count);
end do
print("== Test group 29: paginate ==");
-- a mock that answers COUNT(*) with a total and data queries with page rows.
local PMock = class.extend("PaginateMock", orm.Adapter);
function PMock:__init(o) orm.Adapter.__init(self, o); self.queries = {}; end
function PMock:raw_query(q, p, cb)
    self.queries[#self.queries + 1] = q;
    if (q:find("COUNT(*)", 1, true)) then cb(nil, { { count = 42 } });
    else cb(nil, { { id = 11 }, { id = 12 } }); end
end
function PMock:raw_execute(q, p, cb) cb(nil, { affectedRows = 1 }); end

local pmk = PMock({ dialect = "mysql" });
local pgdb = orm.new({ adapter = pmk, promise = orm.promise.builtin() });
local Item = pgdb:define("items", { id = orm.types.id() });

local result;
Item:where("active", true):order("id"):paginate(2, 10):next(function(r) result = r; end);
check("paginate total from COUNT", result and result.total == 42, result and result.total);
check("paginate page/per_page echoed", result and result.page == 2 and result.per_page == 10);
check("paginate last_page = ceil(total/per_page)", result and result.last_page == 5, result and result.last_page);
check("paginate data is wrapped records", result and #result.data == 2 and result.data[1].id == 11);
check("paginate from/to", result and result.from == 11 and result.to == 12, result and (result.from .. "/" .. result.to));
check("paginate data query has LIMIT/OFFSET", (function()
    for _, q in ipairs(pmk.queries) do if (q:find("LIMIT 10 OFFSET 10", 1, true)) then return true; end end
    return false;
end)());
check("paginate count query honours the WHERE", (function()
    for _, q in ipairs(pmk.queries) do
        if (q:find("COUNT(*)", 1, true) and q:find("WHERE `active` = ?", 1, true)) then return true; end
    end
    return false;
end)());
end do
print("== Test group 30: insert_many ==");
local bm = Mock({ dialect = "sqlite" });
local bdb = orm.new({ adapter = bm, promise = orm.promise.builtin() });
local Log = bdb:define("logs", {
    id = orm.types.id(), level = orm.types.string({ length = 8 }), msg = orm.types.string({ length = 64 }),
});

local n;
Log:insert_many({ { level = "info", msg = "a" }, { level = "warn", msg = "b" }, { level = "info" } }):next(function(c) n = c; end);
local bsql = last_sql(bm);
print("  BULK: " .. bsql);
check("insert_many builds one multi-row INSERT", bsql:find("INSERT INTO `logs` (`level`, `msg`) VALUES (", 1, true) ~= nil, bsql);
check("insert_many NULLs a column missing from a row", bsql:find("NULL", 1, true) ~= nil, bsql);
check("insert_many binds every present value (5)", #bm.calls[#bm.calls].params == 5, #bm.calls[#bm.calls].params);
check("insert_many resolves a count", type(n) == "number", n);

-- empty input is a no-op resolving 0
local z;
Log:insert_many({}):next(function(c) z = c; end);
check("insert_many empty resolves 0", z == 0, z);

-- timestamps are stamped on every row
local tm = Mock({ dialect = "sqlite" });
local tdb = orm.new({ adapter = tm, promise = orm.promise.builtin() });
local Ev = tdb:define("events", { id = orm.types.id(), name = orm.types.string({ length = 16 }) }, { timestamps = true });
Ev:insert_many({ { name = "x" }, { name = "y" } });
check("insert_many stamps timestamps", (function()
    local s = last_sql(tm);
    return s:find("`created_at`", 1, true) ~= nil and s:find("`updated_at`", 1, true) ~= nil;
end)());

-- { records = true } on a RETURNING-capable adapter returns records WITH ids
local RBulk = class.extend("ReturningBulkMock", orm.Adapter);
function RBulk:__init(o) orm.Adapter.__init(self, o); self.calls = {}; end
function RBulk:supports_returning() return true; end
function RBulk:raw_query(q, p, cb) self.calls[#self.calls + 1] = q; cb(nil, { { id = 1, name = "x" }, { id = 2, name = "y" } }); end
function RBulk:raw_execute(q, p, cb) self.calls[#self.calls + 1] = q; cb(nil, { affectedRows = 2 }); end
local rbm = RBulk({ dialect = "sqlite" });
local rbdb = orm.new({ adapter = rbm, promise = orm.promise.builtin() });
local Ev2 = rbdb:define("evs", { id = orm.types.id(), name = orm.types.string({ length = 16 }) });
local recs;
Ev2:insert_many({ { name = "x" }, { name = "y" } }, { records = true }):next(function(r) recs = r; end);
check("insert_many records uses RETURNING", (function()
    for _, q in ipairs(rbm.calls) do if (q:find("RETURNING", 1, true)) then return true; end end
    return false;
end)());
check("insert_many records returns wrapped records with ids",
    recs and #recs == 2 and recs[1].id == 1 and recs[2].id == 2, recs and #recs);

-- { records = true } on a non-RETURNING adapter throws
local NR = orm.new({ adapter = Mock({ dialect = "sqlite" }), promise = orm.promise.builtin() })
    :define("nr", { id = orm.types.id(), name = orm.types.string({ length = 8 }) });
check("insert_many records throws without RETURNING support",
    select(1, pcall(function() NR:insert_many({ { name = "a" } }, { records = true }) end)) == false);
end do
print("== Test group 31: where_between / where_like / where_not / or_where_* ==");
local qm = Mock({ dialect = "mysql" });
local qdb = orm.new({ adapter = qm, promise = orm.promise.builtin() });
local P = qdb:define("players", {
    id = orm.types.id(), name = orm.types.string({ length = 32 }),
    level = orm.types.integer(), banned = orm.types.boolean(),
});

-- between (model delegator) + bound params
qm.query_result = {};
P:where_between("level", 10, 20):all();
check("where_between emits BETWEEN ? AND ?", last_sql(qm):find("`level` BETWEEN ? AND ?", 1, true) ~= nil, last_sql(qm));
check("where_between binds min then max", qm.calls[#qm.calls].params[1] == 10 and qm.calls[#qm.calls].params[2] == 20);

P:query():where_not_between("level", 1, 5):all();
check("where_not_between emits NOT BETWEEN", last_sql(qm):find("`level` NOT BETWEEN ? AND ?", 1, true) ~= nil, last_sql(qm));

-- like / not like
P:where_like("name", "John%"):all();
check("where_like emits LIKE ?", last_sql(qm):find("`name` LIKE ?", 1, true) ~= nil, last_sql(qm));
check("where_like binds the pattern", qm.calls[#qm.calls].params[1] == "John%");
P:query():where_not_like("name", "%bot%"):all();
check("where_not_like emits NOT LIKE ?", last_sql(qm):find("`name` NOT LIKE ?", 1, true) ~= nil, last_sql(qm));

-- not / not_in
P:where_not("banned", true):all();
check("where_not emits !=", last_sql(qm):find("`banned` != ?", 1, true) ~= nil, last_sql(qm));
P:where_not_in("id", { 1, 2 }):all();
check("where_not_in emits NOT IN", last_sql(qm):find("`id` NOT IN (?, ?)", 1, true) ~= nil, last_sql(qm));

-- OR variants chain with the previous condition
P:where("level", ">", 5):or_where_like("name", "admin%"):all();
check("or_where_like uses OR", last_sql(qm):find("`level` > ? OR `name` LIKE ?", 1, true) ~= nil, last_sql(qm));
P:where("id", 1):or_where_between("level", 1, 3):all();
check("or_where_between uses OR", last_sql(qm):find("`id` = ? OR `level` BETWEEN ? AND ?", 1, true) ~= nil, last_sql(qm));
P:where("id", 1):or_where_null("name"):all();
check("or_where_null uses OR + IS NULL", last_sql(qm):find("`id` = ? OR `name` IS NULL", 1, true) ~= nil, last_sql(qm));
end -- close the last group's scope

print(("\n== RESULT: %d passed, %d failed =="):format(passed, failed));
if (failed > 0) then error("self-test failed"); end
