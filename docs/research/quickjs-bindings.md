# QuickJS-NG Zig Bindings (zig-quickjs-ng) — Spec for pi.zig

Scope: source repo `/home/autark/src/zig/zig-quickjs-ng` (HEAD `25836c54bf5e1759cabfb4169e97ac2f3977975b`, remote `git@github.com:mattneel/zig-quickjs-ng.git`, a fork of mitchellh/zig-quickjs-ng) and the vendored copy at `/home/autark/src/zig/pi.zig/zig-pkg/quickjs_ng-0.0.0-0cZnA3A3BACIK0hC-nXSmDiQU69a3ugAqYgftXI8OSJj`.

**Vendored-copy verification:** `diff -r` of `src/`, `build.zig`, and `build.zig.zon` between the source repo and the vendored package returned zero differences. The vendored directory name matches the dependency hash pinned in `/home/autark/src/zig/pi.zig/build.zig.zon` (`.@"quickjs-ng"` → `git+https://github.com/mattneel/zig-quickjs-ng.git#25836c54...`, hash `quickjs_ng-0.0.0-0cZnA3A3BACIK0hC-nXSmDiQU69a3ugAqYgftXI8OSJj`). The vendored copy contains only `build.zig`, `build.zig.zon`, `src/` because the package's `.paths` list (build.zig.zon:6-10) excludes README/examples. **Note:** pi.zig's `build.zig` is still the stock scaffold and does not yet wire in the dependency.

---

## 1. What it wraps

- **Engine:** quickjs-ng pinned as a Zig package dependency: `https://github.com/quickjs-ng/quickjs/archive/3c8f3d68953955950074c41c6e4d999562ae82a7.tar.gz` (build.zig.zon:13-16). That commit reports `QJS_VERSION_MAJOR 0 / MINOR 15 / PATCH 1` (quickjs.h:1433-1436), i.e. quickjs-ng **v0.15.1** (fork commit message: "Update quickjs-ng to master 3c8f3d68 (0.15.1)"). `quickjs.version()` wraps `JS_GetVersion` (src/main.zig:26-28).
- **How the C library is built:** vendored C sources, compiled by Zig into a **static library named `quickjs-ng`** with `link_libc = true`. Only four C files are compiled: `dtoa.c`, `libregexp.c`, `libunicode.c`, `quickjs.c` (build.zig:87-96), with flags `-D_GNU_SOURCE -funsigned-char -fno-omit-frame-pointer -fno-sanitize=undefined -fno-sanitize-trap=undefined -fvisibility=hidden` (build.zig:79-86). **`quickjs-libc.c` is NOT compiled** — so there is no `console`, no `setTimeout`/`setInterval`, no `std`/`os` modules, no worker, no file I/O from JS. (Confirmed: `console`/`setTimeout` only exist in quickjs-libc.c, which is excluded.)
- **C header access:** `translateC()` runs `addTranslateC` on upstream `quickjs.h` producing module `quickjs_c` (build.zig:38-53). The raw translated API is re-exported as `quickjs.c` (src/main.zig:8), so **any C function not covered by the wrappers is still directly callable** (e.g. `quickjs.c.js_strdup`, used in runtime.zig:1019).
- **What the Zig layer adds:** idiomatic opaque-pointer types (`*Runtime`, `*Context`, `*ModuleDef`), an `extern struct Value` ABI-identical to `JSValue` (comptime-asserted, value.zig:2009-2016; NaN-boxing supported for <64-bit targets, value.zig:26-33, 1826-1848), packed-struct flag types asserted against C constants, comptime-wrapped callbacks (zero-cost `callconv(.c)` shims via `@call(.always_inline, ...)`), typed userdata via `Opaque(T)` (`void` → no pointer; else `?*T`; src/opaque.zig), and Zig error unions (`error{JSError}`, `Allocator.Error`) for fallible C calls.
- **Consumer wiring (README.md:76-105):** import `dep.module("quickjs")`, `exe.root_module.linkLibrary(dep.artifact("quickjs-ng"))`, and set `.use_llvm = true` on the executable ("Zig 0.16 fails with splitType errors without LLVM" — README.md:98-99, build.zig:29-30). Zig version is pinned: `minimum_zig_version = "0.16.0"`; the project explicitly supports only released Zig (README.md:50-52).

Public namespace (src/main.zig:8-38): `c`, `cfunc`, `typed_array`, `Atom`, `Context`, `EvalFlags`, `ModuleDef`, `Runtime`, `DumpFlags`, `Value`, `Promise`, `PromiseSettlement`, `PromiseState`, `ClassId`, `ClassDef`, `ClassExoticMethods`, plus `version() [*:0]const u8` and `detectModule(input: []const u8) bool` (wraps `JS_DetectModule` — useful for the eval tool to auto-select script vs module).

---

## 2. Full API surface (exact signatures)

### 2.1 Runtime (src/runtime.zig, `pub const Runtime = opaque`)

Lifecycle:
- `init() Allocator.Error!*Runtime` (JS_NewRuntime)
- `initWithMallocFunctions(mf: *const MallocFunctions, opaque_ptr: ?*anyopaque) Allocator.Error!*Runtime` (JS_NewRuntime2)
- `deinit(*Runtime) void` (JS_FreeRuntime; contexts must be freed first)
- `newContext(*Runtime) Allocator.Error!*Context`, `newContextRaw(*Runtime) Allocator.Error!*Context`

Configuration / limits:
- `setInfo(self, info: [:0]const u8) void`
- `setMemoryLimit(self, limit: usize) void` — 0 disables (JS_SetMemoryLimit)
- `setMaxStackSize(self, size: usize) void` — 0 disables; C default `JS_DEFAULT_STACK_SIZE` = 1 MiB (quickjs.h:443)
- `updateStackTop(self) void` — "Should be called when changing threads" (JS_UpdateStackTop)
- `setGCThreshold(self, usize) void`, `getGCThreshold(self) usize`, `runGC(self) void`, `isLiveObject(self, obj: Value) bool`
- `computeMemoryUsage(self) c.JSMemoryUsage` (struct with malloc_size, memory_used_size, atom_count, obj_count, …)
- `setDumpFlags(self, flags: DumpFlags) void` / `getDumpFlags(self) DumpFlags` — `DumpFlags = packed struct(u64)` with fields `bytecode_final, …, leaks, atom_leaks, mem, objects, atoms, shapes` and preset `DumpFlags.abort_on_leaks` (runtime.zig:757-789); bit layout verified against `JS_DUMP_*` in a test (runtime.zig:1173-1205). Handy in debug builds to catch refcount leaks.
- `setCanBlock(self, can_block: bool) void` (Atomics.wait), `setSharedArrayBufferFunctions(self, sf: typed_array.SharedBufferFunctions) void`

Opaque userdata: `getOpaque(self, comptime T) ?*T` / `setOpaque(self, comptime T, ptr: ?*T) void`.

**Interrupt handler** (the cancellation hook):
```zig
pub fn InterruptHandler(comptime T: type) type = *const fn (Opaque(T), *Runtime) bool; // return true => interrupt
pub fn setInterruptHandler(self: *Runtime, comptime T: type, userdata: Opaque(T), comptime handler: ?InterruptHandler(T)) void
```
(runtime.zig:227-266; wraps JS_SetInterruptHandler.) Called periodically during bytecode execution; returning `true` aborts execution with an **uncatchable** exception (JS `try/catch` cannot swallow it). Test at runtime.zig:937-967 interrupts `while(true){}` after 100 handler calls and observes `result.isException()`. Pass `null, null` to clear.

**Job queue (microtasks):**
- `isJobPending(self) bool` (JS_IsJobPending)
- `getPendingJobContext(self) ?*Context` (borrowed)
- `executePendingJob(self) !?*Context` — returns executed job's context, `null` if none pending, `error.Exception` if the job threw (runtime.zig:572-578)

**Module loader hooks:**
```zig
pub fn ModuleNormalizeFunc(comptime T) type = *const fn (Opaque(T), *Context, [:0]const u8, [:0]const u8) ?[*:0]u8; // base_name, specifier -> js_malloc'ed string or null(+exception)
pub fn ModuleLoaderFunc(comptime T) type    = *const fn (Opaque(T), *Context, [:0]const u8) ?*ModuleDef;
pub fn setModuleLoaderFunc(self, comptime T, userdata: Opaque(T), comptime module_normalize: ?ModuleNormalizeFunc(T), comptime module_loader: ?ModuleLoaderFunc(T)) void
// import-attributes-aware variants (`with { type: "json" }` style):
pub fn ModuleLoaderFunc2(comptime T) type = *const fn (Opaque(T), *Context, [:0]const u8, Value) ?*ModuleDef; // + attributes value (borrowed)
pub fn ModuleCheckSupportedImportAttributes(comptime T) type = *const fn (Opaque(T), *Context, Value) bool;
pub fn setModuleLoaderFunc2(self, comptime T, userdata, comptime normalize: ?ModuleNormalizeFunc(T), comptime loader: ?ModuleLoaderFunc2(T), comptime check_attrs: ?ModuleCheckSupportedImportAttributes(T)) void
pub fn ModuleNormalizeFunc2(comptime T) type = *const fn (Opaque(T), *Context, [:0]const u8, [:0]const u8, Value) ?[*:0]u8;
pub fn setModuleNormalizeFunc2(self, comptime T, comptime module_normalize: ?ModuleNormalizeFunc2(T)) void
```
(runtime.zig:295-512.) The normalizer's returned string must be allocated with the JS allocator — the in-repo test uses `c.js_strdup(inner_ctx.cval(), module_name.ptr)` (runtime.zig:1019). Full working example with `import ... with { flavor: "zig" }` at runtime.zig:990-1074.

Classes: `newClass(self, class_id: class.Id, def: *const class.Def) !void` (error.ClassRegistrationFailed), `isRegisteredClass(self, class.Id) bool`, `getClassName(self, class.Id) Atom`.

Finalizers: `addFinalizer(self, comptime T, userdata: Opaque(T), comptime finalizer: *const fn (Opaque(T), *Runtime) void) Allocator.Error!void` — run in reverse order at `deinit` (runtime.zig:603-628).

Promise observability:
- `PromiseHookType = enum(c_uint) { init, before, after, resolve }`
- `PromiseHook(T) = *const fn (Opaque(T), *Context, PromiseHookType, Value, Value) void`; `setPromiseHook(self, comptime T, userdata, comptime hook: ?PromiseHook(T)) void`
- `HostPromiseRejectionTracker(T) = *const fn (Opaque(T), *Context, Value promise, Value reason, bool is_handled) void`; `setHostPromiseRejectionTracker(...)` — fires for unhandled rejections after job pumping (test runtime.zig:1313-1353). pi.zig should install this to surface unhandled rejections in tool output / extension logs.

`MallocFunctions = extern struct { calloc, malloc, free, realloc: C fn ptrs, malloc_usable_size: ?... }` (runtime.zig:22-35), size/align asserted against `JSMallocFunctions`.

### 2.2 Context (src/context.zig, `pub const Context = opaque`)

- `init(rt: *Runtime) Allocator.Error!*Context`, `initRaw(rt) Allocator.Error!*Context`, `deinit(self) void`, `dup(self) *Context` (refcount), `getRuntime(self) *Runtime`, `getGlobalObject(self) Value` (owned)
- Opaque userdata: `getOpaque(comptime T) ?*T` / `setOpaque(comptime T, ?*T)` — the natural place to hang a per-extension or per-eval-session host state pointer.

**Evaluation:**
```zig
pub fn eval(self, input: []const u8, filename: [:0]const u8, flags: EvalFlags) Value
pub fn eval2(self, input: []const u8, options: *EvalOptions) Value            // JS_Eval2 (filename + line_num)
pub fn evalThis(self, this_obj: Value, input, filename, flags) Value
pub fn evalThis2(self, this_obj: Value, input, options: *EvalOptions) Value
pub fn evalFunction(self, func_obj: Value) Value    // runs bytecode from compile_only (takes ownership)
```
```zig
pub const EvalFlags = packed struct(c_int) {
    type: Type = .global,          // enum(u2){ global, module, direct, indirect }
    _reserved: u1, strict: bool = false, _unused: u1,
    compile_only: bool = false,    // returns JS_TAG_FUNCTION_BYTECODE or JS_TAG_MODULE value
    backtrace_barrier: bool = false,
    async_module: bool = false,    // = JS_EVAL_FLAG_ASYNC: allow top-level await in a *global* script; JS_Eval returns a Promise. (Name is misleading; only valid with .type=.global per quickjs.h:461-463)
    _padding: u24,
};
pub const EvalOptions = extern struct { version: c_int = 1, flags: EvalFlags = .{}, filename: [*:0]const u8 = "<eval>", line_num: c_int = 1 };
```
Bit layout tested against C (context.zig:575-595). Result convention: **returns a `Value`; check `.isException()`, then `ctx.getException()`** — no Zig error union on eval. Evaluating with `.type = .module` returns the module-evaluation **Promise** (quickjs-ng top-level-await semantics; quickjs.c `JS_EvalFunctionInternal` → `js_evaluate_module`), so a module isn't finished until the job queue drains; inspect via `Value.promiseState/promiseResult`.

- `loadModule(self, basename: [*:0]const u8, filename: [*:0]const u8) Value` (JS_LoadModule, drives the registered loader)
- `getScriptOrModuleName(self, n_stack_levels: i32) Atom`
- `enqueueJob(self, comptime job_func: *const fn (*Context, []const Value) Value, args: []const Value) Allocator.Error!void` (context.zig:243-269) — host-side microtask enqueue; args are dup'ed.

Exceptions: `getException(self) Value` (owned; clears pending), `hasException(self) bool`, `resetUncatchableError(self) void`, `throwOutOfMemory(self) Value`; factories `newTypeError/newSyntaxError/newReferenceError/newRangeError/newInternalError(self, msg: [:0]const u8) Value` and throwing versions `throwTypeError/throwSyntaxError/throwReferenceError/throwRangeError/throwInternalError(self, msg) Value` (all funnel through `"%s"` so no format-string hazards; context.zig:449-514). Error objects carry `message` and `stack` properties (test context.zig:1078-1102).

Strings: `freeCString(self, ptr: [*:0]const u8) void`, `freeCStringUTF16(self, str: []const u16) void`.

Intrinsics (for `initRaw` sandbox construction; context.zig:309-409): `addIntrinsicBaseObjects, addIntrinsicDate, addIntrinsicEval, addIntrinsicRegExpCompiler (void), addIntrinsicRegExp, addIntrinsicJSON, addIntrinsicProxy, addIntrinsicMapSet, addIntrinsicTypedArrays, addIntrinsicPromise, addIntrinsicBigInt, addIntrinsicWeakRef, addPerformance, addIntrinsicDOMException, addIntrinsicAToB` — all `error{JSError}!void` except the RegExp compiler. A default `Context.init` includes everything (atob/btoa, DOMException, performance.now verified in tests, context.zig:805-851). This is the mechanism for a **locked-down extension sandbox** (e.g. omit `eval`).

Class protos: `getClassProto(self, class.Id) Value`, `setClassProto(self, class.Id, proto: Value) void` (takes ownership), `getFunctionProto(self) Value`.

### 2.3 Value (src/value.zig, `pub const Value = extern struct`)

Constants: `Value.null, .undefined, .false, .true, .exception, .uninitialized`; `Tag = enum(i64)` mirrors `JS_TAG_*` including `module`, `function_bytecode`, `string_rope`, `short_big_int`.

Generic conversion **Zig → JS**: `init(ctx: *Context, val: anytype) Value` (value.zig:108-155) — accepts `Value`, `bool`, `void`/`null` → null, optionals, ints (≤32 bit exact; ≤63-bit via int64; 64-bit falls to float64), comptime ints/floats, floats ≤64, `[]const u8`/`*const [N]u8` → string; anything else throws a conversion-error string and returns the exception value.

Typed constructors: `initBool(bool)`, `initInt32(i32)`, `initInt64(i64)` (int if fits else float64), `initUint32(u32)`, `initUint64(u64)`, `initFloat64(f64)` — these are context-free; `initNumber(ctx,f64)`, `initBigInt64(ctx,i64)`, `initBigUint64(ctx,u64)`, `initString(ctx,[*:0]const u8)`, `initStringLen(ctx,[]const u8)`, `initStringUTF16(ctx,[]const u16)`, `initObject(ctx)`, `initObjectProto(ctx,proto)`, `initObjectClass(ctx,class.Id)`, `initArray(ctx)`, `initArrayFrom(ctx, values: []const Value)` (takes ownership), `initDate(ctx, epoch_ms: f64)`, `initSymbol(ctx, desc, is_global: bool)`, `initError(ctx)`, `initProxy(ctx,target,handler)`.

**Host functions** (all `comptime func`):
```zig
initCFunction(ctx, comptime func: cfunc.Func, name: [:0]const u8, length: i32) Value
initCFunction2(ctx, comptime func, name, length, cproto: cfunc.Proto, magic: i32) Value      // .constructor etc.
initCFunction3(ctx, comptime func, name, length, cproto, magic, proto_val: Value, n_fields: i32) Value
initCFunctionData(ctx, comptime func: cfunc.FuncData, length, magic, data: []const Value) Value   // JSValue closure captures
initCFunctionData2(ctx, comptime func, name, length, magic, data) Value
initCClosure(ctx, comptime T, comptime func: cfunc.Closure(T), name, comptime finalizer: ?cfunc.ClosureFinalizer(T), length, magic, userdata: Opaque(T)) Value  // native pointer capture + finalizer — the workhorse for pi.zig host APIs
```
Callback shapes (src/cfunc.zig): `Func = *const fn (?*Context, Value this, []const c.JSValue args) Value`; `FuncMagic` adds `c_int magic`; `FuncData` adds `magic, [*c]c.JSValue func_data`; `Closure(T) = *const fn (?*Context, Value, []const c.JSValue, c_int, Opaque(T)) Value`; `Getter = *const fn (?*Context, Value) Value`; `Setter = *const fn (?*Context, Value, Value) Value` (+ magic variants). Note **args arrive as `[]const c.JSValue`** (borrowed); convert each with `Value.fromCVal(arg)`; do not deinit them. Signal errors by returning `ctx.throwTypeError(...)` etc. `cfunc.Proto = enum(c_uint) { generic, generic_magic, constructor, constructor_magic, constructor_or_func, constructor_or_func_magic, f_f, f_f_f, getter, setter, getter_magic, setter_magic, iterator_next }`.

Bulk definition: `setPropertyFunctionList(self, ctx, list: []const cfunc.FunctionListEntry) error{JSError}!void` with builders `cfunc.FunctionListEntryHelpers.func/funcWithFlags/funcMagic/getset/getsetMagic/propString/propInt32/propInt64/propDouble/propUndefined/propSymbol/propBool` (cfunc.zig:318-500).

ArrayBuffer/TypedArray: `initArrayBuffer(ctx, comptime T, buf: []u8, comptime free_func: ?typed_array.FreeBufferDataFunc(T), userdata: Opaque(T), is_shared: bool)` (zero-copy, ownership transfer w/ free callback), `initArrayBufferCopy(ctx, []const u8)`, `initTypedArray(ctx, args: []const Value, array_type: typed_array.Type)`, `initUint8Array(...)`, `initUint8ArrayCopy(ctx, []const u8)`; accessors `getArrayBuffer(ctx) ?[]u8`, `getUint8Array(ctx) ?[]u8`, `getTypedArrayBuffer(ctx) ?typed_array.Buffer {value, byte_offset, byte_length, bytes_per_element}`, `getTypedArrayType() ?typed_array.Type`, `detachArrayBuffer(ctx)`, `setImmutableArrayBuffer/isImmutableArrayBuffer`. `typed_array.Type = enum(c_uint){ uint8_clamped, int8, uint8, int16, uint16, int32, uint32, big_int64, big_uint64, float16, float32, float64 }`.

Refcounting: `dup(ctx) Value`, `dupRT(rt) Value`, `deinit(ctx) void`, `deinitRT(rt) void`, plus fork-added bulk helpers `deinitMany(ctx, []const Value)`, `deinitManyRT(rt, []const Value)` (value.zig:594-612). Everything returned by eval/getProperty/call is owned and must be `deinit`ed; the codebase convention is immediate `defer`.

Predicates: `isNull, isUndefined, isBool, isNumber, isBigInt, isString, isSymbol, isObject, isException, isUninitialized, isModule, isArray, isProxy, isDate, isPromise, isError, isUncatchableError, isArrayBuffer, isRegExp, isMap, isSet, isWeakRef, isWeakSet, isWeakMap, isDataView, isFunction(ctx), isAsyncFunction, isConstructor(ctx)` — all `bool`.

**JS → Zig conversions:** `toBool(ctx) error{JSError}!bool`, `toInt32/!i32`, `toUint32/!u32`, `toInt64/!i64`, `toIndex/!u64`, `toFloat64/!f64`, `toBigInt64/!i64`, `toBigUint64/!u64`; value-level `toNumber/toStringValue/toObject/toPropertyKey(ctx) Value`; strings: `toZigSlice(ctx) ?[:0]const u8` (free via `ctx.freeCString(slice.ptr)`), `toCStringLen(ctx) ?struct{ptr: [*:0]const u8, len: usize}`, `toCString(ctx) ?[*:0]const u8`, `toCStringUTF16(ctx) ?[]const u16`.

Properties: `getProperty(ctx, prop: Atom) Value`, `getPropertyStr(ctx, name: [*:0]const u8) Value`, `getPropertyUint32/Int64`, `setProperty(ctx, Atom, Value) error{JSError}!void` (+ Str/Uint32/Int64 variants; all take ownership of the value), `hasPropertyStr/!bool`, `deletePropertyStr/!bool`, `getPrototype/setPrototype`, `setConstructor`, `setConstructorBit`, `getLength/!i64`, `setLength`, `isExtensible/preventExtensions/seal/freeze`, `defineProperty(ctx, Atom, val, getter, setter, PropertyFlags) error{JSError}!bool`, `definePropertyValue(+Uint32/Str)`, `definePropertyGetSet`, `getOwnPropertyNames(ctx, GetPropertyNamesFlags) error{JSError}![]const PropertyEnum` + `freePropertyEnum`, `getOwnProperty(ctx, Atom) error{JSError}!?PropertyDescriptor`. `PropertyFlags = packed struct(c_int)` mirroring `JS_PROP_*` incl. `has_*` mask fields and `PropertyFlags.default` (C_W_E); `GetPropertyNamesFlags` has presets `.strings/.symbols/.all/.enum_strings` matching `Object.keys` etc.

Comparison: `isEqual(ctx)/!bool` (==), `isStrictEqual(ctx) bool` (===), `isSameValue`, `isSameValueZero`, `isInstanceOf/!bool`.

Calls: `call(ctx, this: Value, args: []const Value) Value`, `callConstructor(ctx, args) Value`, `callConstructor2(ctx, new_target, args) Value`, `invoke(ctx, method: Atom, args) Value` — all return owned Value, check `isException`.

JSON (key for tool-arg/result marshaling): `parseJSON(ctx, buf: []const u8, filename: [*:0]const u8) Value` and `jsonStringify(self, ctx, replacer: Value, space: Value) Value`.

Exceptions: `throw(ctx) Value` (takes ownership), `setUncatchableError(ctx)`, `clearUncatchableError(ctx)`.

**Promises:**
- `promiseState(ctx) PromiseState` — `enum(c_int){ not_a_promise = -1, pending = 0, fulfilled = 1, rejected = 2 }`
- `promiseResult(ctx) Value` (owned)
- `initSettledPromise(ctx, settlement: PromiseSettlement /*resolved|rejected*/, value: Value) Value`
- `initPromiseCapability(ctx) Value.Promise` where `Promise = struct { value: Value, resolve: Value, reject: Value, deinit(ctx) }` (value.zig:1714-1742). Host async pattern (examples/async-promises/main.zig:46-67): create capability, return `.value` to JS, later `_ = promise.resolve.call(ctx, .undefined, &.{result})`, then pump jobs.

Class opaque data: `getClassId() class.Id`, `setOpaque(?*anyopaque) bool`, `getOpaque(comptime T, class.Id) ?*T`, `getOpaque2(ctx, comptime T, class.Id) ?*T` (throws JS TypeError on class mismatch), `getAnyOpaque(comptime T) struct{ptr: ?*T, class_id: class.Id}`.

C interop: `fromCVal(c.JSValue) Value` / `cval() c.JSValue` (bitcasts).

Modules-as-values: `isModule() bool`, `resolveModule(ctx) !void` (error.ModuleResolutionFailed; for use after `JS_ReadObject` — see gaps).

### 2.4 Atom (src/atom.zig)

`Atom = enum(u32) { null = 0, _ }` with `init(ctx, [:0]const u8)`, `initLen(ctx, []const u8)`, `initUint32(ctx, u32)`, `fromValue(ctx, Value)`, `dup/dupRT`, `deinit/deinitRT/deinitMany/deinitManyRT`, `toValue(ctx) Value`, `toString(ctx) Value`, `toCString(ctx) ?[*:0]const u8`, `toCStringLen`, `toZigSlice(ctx) ?[:0]const u8`.

### 2.5 ModuleDef (src/module.zig, `opaque`)

- `InitFunc = *const fn (*Context, *ModuleDef) bool`
- `init(ctx, name: [:0]const u8, comptime func: InitFunc) ?*ModuleDef` (JS_NewCModule)
- `addExport(self, ctx, name: [:0]const u8) bool` (declare before instantiation) / `setExport(self, ctx, name, val: Value) bool` (inside InitFunc; takes ownership)
- `setPrivateValue(self, ctx, val) error{JSError}!void` / `getPrivateValue(self, ctx) Value`
- `getImportMeta(self, ctx) Value` (mutable object — where pi.zig sets `import.meta.url`), `getName(self, ctx) Atom`, `getNamespace(self, ctx) Value`
Native-module registration pattern with a comptime dispatching loader: examples/modules/main.zig:10-29.

### 2.6 Classes (src/class.zig)

- `Id = enum(u32) { invalid = 0, _ }` with `Id.new(rt: *Runtime) Id`
- `Def = extern struct { class_name: [*:0]const u8 = "", finalizer: ?*const c.JSClassFinalizer = null, gc_mark: ?*const c.JSClassGCMark = null, call: ?*const c.JSClassCall = null, exotic: ?*ExoticMethods = null }` — note finalizer/gc_mark/call take **raw C signatures**; the classes example writes `fn finalizer(rt: *quickjs.Runtime, val: quickjs.Value) callconv(.c) void` and installs it via `.finalizer = @ptrCast(&finalizer)` (examples/classes/main.zig:31-59). `ExoticMethods` is a full extern mirror of `JSClassExoticMethods` (raw C fn ptrs) enabling Proxy-like custom classes.
- Full native-class recipe (examples/classes/main.zig): `Id.new` → `rt.newClass(id, &def)` → build proto object + `setPropertyFunctionList` → `ctx.setClassProto(id, proto)` → constructor via `initCFunction2(..., .constructor, 0)` → in constructor `initObjectClass(ctx,id)` + `setOpaque(ptr)`; methods recover state with `getOpaque2`.

---

## 3. std.Io integration

**None.** `grep std.Io src/` → zero hits; the only `std.Io` usage is stdout writing inside example `main` functions. The bindings provide no timers, no event loop, no async bridging. The embedder owns the schedule:

- **Job pumping is manual and synchronous:** `while (rt.isJobPending()) _ = try rt.executePendingJob();` (examples/async-promises/main.zig:71-73). All `.then`/`await` continuations run only inside `executePendingJob`.
- **Async host ops** are bridged by hand: host fn returns `initPromiseCapability(...).value`; when the Zig-side operation completes (on the pi.zig std.Io event loop), call `resolve.call(...)`/`reject.call(...)` **on the JS thread**, then drain the job queue.
- pi.zig therefore needs a small "JS executor" layer: single owner thread (or mutex-serialized section) that (1) runs evals, (2) drains jobs after every eval and after every host promise settlement, (3) implements `setTimeout`/`queueMicrotask` on the agent's std.Io timers by resolving capabilities, (4) checks cancellation between pump iterations (see §5).

---

## 4. Maturity, tests, gaps

**Maturity signals**
- 165 `test` blocks across src (value 65, context 37, runtime 23, atom 16, class 11, module 6, cfunc 4, main 2, typed_array 1); tests exercise real JS via `eval` per the repo's own guide (AGENTS.md:33-35). Zero TODO/FIXME markers in src.
- Every C-layout type has comptime size/align asserts and constants-match tests (e.g. context.zig:561-565, value.zig:2009-2016, runtime.zig:1173-1205).
- CI (.github/workflows/test.yml): tests + all four examples on native and x86-linux-musl (qemu), Nix flake pins Zig 0.16.0. Examples: `minimal`, `modules`, `classes`, `async-promises`.
- Coverage: README claims ~95%. Verified: of 231 `JS_EXTERN` functions in quickjs.h, all but 17 are called from the wrappers (one hit, `JS_PRINTF_FORMAT_ATTR`, is a macro false positive).

**Unwrapped C APIs** (still callable through `quickjs.c`): `JS_WriteObject`, `JS_WriteObject2`, `JS_ReadObject`, `JS_ReadObject2` (bytecode/serialization — needed for **bytecode caching** of extensions), `JS_MarkValue` (needed if a custom class's `gc_mark` must trace held JSValues — pi.zig will need this for host objects retaining callbacks), `JS_NewObjectFrom`, `JS_NewObjectFromStr` (fast batch object construction), `JS_NewObjectProtoClass`, `JS_AddModuleExportList`/`JS_SetModuleExportList`, `JS_NewAtomString`, `JS_ToCStringLen2`, `JS_ToInt64Ext`, `JS_ToObjectString`, `JS_DumpMemoryUsage`, `JS_FreeCStringRT`, `JS_SetIsHTMLDDA`.

**Rough edges relevant to pi.zig**
1. **No disk module loader included.** The loader hook returns `?*ModuleDef`, but there is no helper to compile a source file into a `*ModuleDef`. Standard recipe: in the loader, read the file, `ctx.eval(src, filename, .{ .type = .module, .compile_only = true })`, then extract the pointer from the returned Value (tag `.module`): `@as(*ModuleDef, @ptrCast(result.u.ptr))` — the bindings expose the union (`Value.u`) but provide no `toModuleDef()`; pi.zig should add one thin helper.
2. **Module eval returns a Promise** — the result of a `.type = .module` eval must be treated as a promise (state pending until jobs drain; rejection carries the module error). Not documented in the bindings; confirmed in quickjs.c.
3. `EvalFlags.async_module` is misnamed: it is `JS_EVAL_FLAG_ASYNC` = top-level-await-in-*global*-script (returns a promise), not a module flag.
4. Host-fn args are `[]const c.JSValue`, not `[]const Value` — minor friction, per-arg `Value.fromCVal`.
5. Class callbacks (`finalizer`, `gc_mark`, `call`) need `@ptrCast` to raw C fn-pointer types.
6. The allocator cannot be a `std.mem.Allocator` (see §6).
7. No `console`, no timers, no TextEncoder/TextDecoder (absent from quickjs-ng 0.15.1 core entirely — grep of quickjs.c/quickjs-libc.c = 0 hits), no `structuredClone`, no `fetch` — all host work.

**What pi.zig must build on top** (informed by upstream oh-my-pi's eval tool contract: persistent per-session "JS VM", per-call timeout seconds, `reset` wipes the kernel, streamed output with byte caps — inspiration/packages/coding-agent/src/tools/eval.ts:31-33,88-89 and eval-backends.ts allowances `PI_JS`/`eval.js` default-on):
- `console.log/warn/error/debug` writing into the tool's OutputSink/TailBuffer equivalent (upstream streams with `DEFAULT_MAX_BYTES` caps) and into extension logs; implement via `initCClosure` + a host sink pointer.
- `setTimeout/setInterval/clearTimeout/queueMicrotask` on the agent event loop.
- `TextEncoder/TextDecoder` (or expose host UTF-8 helpers), `structuredClone` (can be `JSON` round-trip initially), `atob/btoa` already intrinsic.
- `fetch` (host HTTP via ai.zig's client) honoring the agent's download URL allow/deny policy.
- ES module resolution from disk for extensions (normalize relative specifiers against `module_base_name`, load+compile, set `import.meta.url`), plus the C-module bridge (`ModuleDef.init`) for the host API surface (`pi.*`: tool registration, event subscription, session access).
- Bytecode cache for extensions via raw `c.JS_WriteObject`/`c.JS_ReadObject` + `Value.resolveModule` + `Context.evalFunction` (optional optimization).
- Persistent interpreter session: one `Runtime`+`Context` kept across eval-tool calls; `reset` = destroy context (or runtime) and recreate; result rendering = `jsonStringify` / `toStringValue` of the completion value, plus captured console output.

---

## 5. Execution limits + cancellation integration

Available primitives map cleanly onto the agent's cancellation model:

1. **Cooperative interrupt (cancel + deadline).** `rt.setInterruptHandler(HostState, &state, handler)` where `handler: fn (?*HostState, *Runtime) bool` returns true to abort. Called periodically during bytecode execution on the executing thread. Implementation for pi.zig: handler checks (a) an `std.atomic.Value(bool)` set by the agent's cancel path (AgentCommand mailbox), and (b) a monotonic deadline (`std.time.Instant`) armed per eval-tool call from the upstream-style per-call `timeout` param. Zero JS-side cooperation needed; `while(true){}` is interruptible (proven by test runtime.zig:937-967).
2. **Interrupt result semantics.** The abort surfaces as an exception with the **uncatchable** flag — script `try/catch` cannot suppress it; `Value.isUncatchableError` distinguishes cancellation from ordinary JS errors so the tool can report "timed out/cancelled" vs "threw". After harvesting, call `ctx.resetUncatchableError()` (context.zig:87-92) before reusing the persistent session context.
3. **Memory limit.** `rt.setMemoryLimit(bytes)` — allocation beyond the cap makes JS fail with OOM exceptions (test runtime.zig:807-830). Set per interpreter/extension runtime at creation; also `setGCThreshold`, `runGC`, and `computeMemoryUsage` for reporting/telemetry.
4. **Stack limit.** `rt.setMaxStackSize(bytes)` (default 1 MiB); runaway recursion becomes a catchable RangeError-style exception (test runtime.zig:832-850). Call `rt.updateStackTop()` if evals ever migrate threads.
5. **Job-queue cancellation.** The interrupt handler only fires *inside* JS execution; the pump loop must independently check the cancel flag between `executePendingJob()` calls, and a cancelled session should stop settling host promises. `executePendingJob` returning `error.Exception` must not abort the drain loop (see test runtime.zig:1345-1347's `catch break` pattern — pi.zig should log and continue instead).
6. **Isolation granularity.** One `Runtime` per trust domain (interpreter sessions vs each extension, or one runtime + context-per-extension since contexts share an interrupt handler/limits at runtime scope). Since limits and the interrupt handler are **runtime-scoped**, per-extension deadlines require either separate runtimes or handler state keyed by "currently executing owner".
7. **Threading rules** (engine-level): a runtime and everything created from it is single-threaded — no internal locking; use one owner thread per runtime, or externally serialize. `setCanBlock(true)` only if Atomics.wait should be permitted (leave false for agent embedding). Multiple runtimes may run on different threads concurrently.

## 6. Allocator integration

QuickJS does **not** use a Zig `std.mem.Allocator`. Default `Runtime.init()` uses libc malloc. `initWithMallocFunctions` takes C-style callbacks (`calloc/malloc/free/realloc(+malloc_usable_size)`) with an opaque pointer; the doc comment states the constraint explicitly: a Zig Allocator "cannot be directly wrapped because Zig allocators require the original allocation size for free and realloc, but this C-style interface does not provide it. Use allocators that internally track sizes (e.g., libc malloc via std.c.malloc/std.c.free)" (runtime.zig:13-19; working example at runtime.zig:1207-1255). If pi.zig wants arena/tracked memory it must implement size-prefix headers itself; otherwise accept libc and enforce budgets via `setMemoryLimit`.

