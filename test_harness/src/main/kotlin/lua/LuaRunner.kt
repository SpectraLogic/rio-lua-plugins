package com.github.berkeleysquare.lua

import com.github.berkeleysquare.PluginBridge
import org.luaj.vm2.Globals
import org.luaj.vm2.LuaError
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.luaj.vm2.lib.jse.CoerceJavaToLua
import org.luaj.vm2.lib.jse.JsePlatform
import org.slf4j.Logger
import org.slf4j.LoggerFactory
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlin.system.exitProcess

private val scriptDir: Path = Paths.get(System.getProperty("user.dir"))
private val workDir: Path = Paths.get(System.getProperty("user.dir"))

fun main(args: Array<String>) {
    val logger = LoggerFactory.getLogger("LuaRunner")

    val scriptPath: Path =
        when {
            args.isNotEmpty() -> resolveScript(args[0])
            else -> {
                logger.error("Usage: ./gradlew runLua -PluaScript=<name-or-path>")
                logger.error("Scripts are resolved relative to $scriptDir unless given as an absolute path.")
                exitProcess(1)
            }
        }

    if (!Files.exists(scriptPath)) {
        logger.error("Script not found: $scriptPath")
        exitProcess(1)
    }

    val inputPath = workDir.resolve("source-input").resolve(System.getProperty("luaInput") ?: "test.jpg").toString()
    val outputPath = System.getProperty("luaOutput") ?: workDir.resolve("proxy-output").toString()
    val clipPath = workDir.resolve(System.getProperty("luaClip") ?: "clip-input")
    Files.createDirectories(Paths.get(outputPath))
    val inputFileName = Paths.get(inputPath).fileName.toString()
    val bridge = PluginBridge(inputFileName, logger, clipPath.toString())

    val globals = JsePlatform.standardGlobals()
    globals.set("rio", CoerceJavaToLua.coerce(bridge))
    globals.set("input", inputPath)
    globals.set("working_directory", outputPath.toString() + "/")
    globals.load(IO_POPEN_PATCH).call()
    registerModules(globals)
    globals.get("package").set(
        "path",
        "$scriptDir/?.lua;$scriptDir/lib/?.lua;$scriptDir/../lib/?.lua;?.lua;$scriptDir/?/init.lua",
    )

    logger.info("Running ${scriptPath.fileName} (input_path=$inputPath, output_path=$outputPath)")
    try {
        val chunk = globals.loadfile(scriptPath.toString())
        chunk.call()

        val plugin = globals.get("plugin")
        if (!plugin.istable()) {
            // Legacy style: the chunk itself did all the work when it ran above.
            return
        }

        val execute = plugin.get("execute")
        if (!execute.isfunction()) {
            logger.warn("plugin table found but no execute() function; nothing to run")
            return
        }

        val settings = buildConfig(globals, plugin.get("schema"), logger)
        globals.set("settings", settings)
        logger.info("Calling plugin.execute() with settings: $settings")
        execute.call()
    } catch (e: LuaError) {
        logger.error("Lua error: ${e.message}")
        exitProcess(2)
    }
}

// Builds the config table passed to plugin.execute(): defaults come from decoding
// plugin.schema()'s JSON, then an optional -DluaSettings=<path-to-json> file is
// merged on top -- the escape hatch for settings with no default (e.g. required
// fields like an S3 bucket name) that schema() alone can't supply.
private fun buildConfig(globals: Globals, schema: LuaValue, logger: Logger): LuaTable {
    val config = LuaTable()
    val dkjson = globals.get("require").call(LuaValue.valueOf("dkjson"))

    if (schema.isfunction()) {
        val decoded = dkjson.get("decode").call(schema.call())
        if (decoded.istable()) {
            val fields = decoded.checktable()
            for (i in 1..fields.length()) {
                val field = fields.get(i)
                val key = field.get("key")
                val default = field.get("default")
                if (!key.isnil() && !default.isnil()) {
                    config.set(key, default)
                }
            }
        } else {
            logger.warn("plugin.schema() did not return decodable JSON")
        }
    }

    val overridesPath = System.getProperty("luaSettings")
    if (overridesPath != null) {
        val overridesJson = Files.readString(Paths.get(overridesPath))
        val overrides = dkjson.get("decode").call(LuaValue.valueOf(overridesJson))
        if (overrides.istable()) {
            for (key in overrides.checktable().keys()) {
                config.set(key, overrides.get(key))
            }
            logger.info("Applied settings overrides from $overridesPath")
        } else {
            logger.warn("Could not decode luaSettings file: $overridesPath")
        }
    }

    return config
}

private fun resolveScript(arg: String): Path {
    val direct = Paths.get(arg)
    if (direct.isAbsolute) return direct
    val inDir = scriptDir.resolve(arg)
    return if (Files.exists(inDir) || arg.endsWith(".lua")) inDir else scriptDir.resolve("$arg.lua")
}

// LuaJ's built-in io.popen is a non-functional stub: it doesn't fork a subprocess
// and close() always returns falsy. Replace it with a wrapper around rio:exec so
// production scripts using io.popen work unchanged in the test harness.
private const val IO_POPEN_PATCH = """
io.popen = function(cmd)
    local output = rio:exec(cmd) or ""
    local closed = false
    local pos = 1
    local handle = {}
    function handle:read(fmt)
        if closed then return nil end
        fmt = fmt or "*l"
        if fmt == "*a" or fmt == "a" then
            local rest = output:sub(pos)
            pos = #output + 1
            return rest
        elseif fmt == "*l" or fmt == "l" or fmt == "*L" or fmt == "L" then
            if pos > #output then return nil end
            local nl = output:find("\n", pos, true)
            local line
            if nl then
                line = output:sub(pos, nl - 1)
                pos = nl + 1
            else
                line = output:sub(pos)
                pos = #output + 1
            end
            if fmt == "*L" or fmt == "L" then line = line .. "\n" end
            return line
        else
            local n = tonumber(fmt)
            if not n then return nil end
            local chunk = output:sub(pos, pos + n - 1)
            pos = pos + n
            return chunk
        end
    end
    function handle:close()
        closed = true
        return true
    end
    function handle:lines()
        return function() return handle:read("*l") end
    end
    return handle
end
"""
