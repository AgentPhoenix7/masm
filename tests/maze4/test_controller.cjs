const vm = require("node:vm"),
  fs = require("node:fs"),
  assert = require("node:assert/strict");
const { webcrypto } = require("node:crypto");
const code = fs.readFileSync("assignment-3/phone/controller.js", "utf8");
const storage = new Map();
function load() {
  const nodes = new Map();
  const ctx = {
    crypto: webcrypto,
    sessionStorage: {
      getItem: (k) => storage.get(k) || null,
      setItem: (k, v) => storage.set(k, v),
      removeItem: (k) => storage.delete(k),
    },
    document: {
      hidden: true,
      getElementById: (id) => {
        if (!nodes.has(id))
          nodes.set(id, {
            addEventListener() {},
            classList: { remove() {}, add() {} },
          });
        return nodes.get(id);
      },
      querySelectorAll: () => [],
      addEventListener() {},
    },
    window: { addEventListener() {} },
    setInterval() {},
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  return ctx;
}
const first = load(),
  second = load();
assert.equal(
  vm.runInContext("attempt", first),
  vm.runInContext("attempt", second),
  "reload must preserve pending join identity",
);
console.log(
  "PASS: browser reload preserves non-credential join retry identity",
);
