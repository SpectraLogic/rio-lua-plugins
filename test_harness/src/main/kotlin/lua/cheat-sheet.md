# Update Mock Lua Bridge globals
```
// String global  (input_path, output_path — already done)
globals.set("input_path", inputPath)

// Number global  — wrap with LuaValue.valueOf
globals.set("admin_user_id", LuaValue.valueOf(1234L))
globals.set("default_quality", LuaValue.valueOf(0.85))

// Boolean global
globals.set("dry_run", LuaValue.valueOf(true))

// Java object (call methods on it from Lua)
globals.set("rio", CoerceJavaToLua.coerce(bridge))

// Table (key/value config — Lua sees it as a regular table)
val cfg = LuaTable()
cfg.set("codec", LuaValue.valueOf("h264"))
cfg.set("bitrate", LuaValue.valueOf(4500))
globals.set("config", cfg)
// In Lua: config.codec, config.bitrate

// List/array
val list = LuaTable()
listOf("h264", "h265", "av1").forEachIndexed { i, v ->
    list.set(i + 1, LuaValue.valueOf(v))   // Lua arrays are 1-indexed
}
globals.set("codecs", list)
// In Lua: codecs[1], #codecs, ipairs(codecs)
```
