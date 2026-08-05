package com.github.berkeleysquare.lua

import com.google.gson.GsonBuilder
import com.google.gson.JsonElement
import com.google.gson.JsonParser
import org.luaj.vm2.Globals
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.luaj.vm2.Varargs
import org.luaj.vm2.lib.OneArgFunction
import org.luaj.vm2.lib.VarArgFunction
import org.luaj.vm2.lib.ZeroArgFunction
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.Base64

// LuaJ doesn't ship socket.http / ltn12 / base64 / dkjson. Production scripts
// use these standard names, so we register Kotlin-backed stand-ins via
// package.preload so require("...") resolves to them.
fun registerModules(globals: Globals) {
    val preload = globals.get("package").get("preload")
    preload.set("socket.http", PreloadModule(makeSocketHttp()))
    preload.set("ltn12", PreloadModule(makeLtn12()))
    preload.set("base64", PreloadModule(makeBase64()))
    preload.set("dkjson", PreloadModule(makeDkjson()))
}

private class PreloadModule(private val mod: LuaTable) : OneArgFunction() {
    override fun call(modname: LuaValue): LuaValue = mod
}

// -------- base64 --------

private fun makeBase64(): LuaTable {
    val t = LuaTable()
    t.set("encode", object : OneArgFunction() {
        override fun call(arg: LuaValue): LuaValue {
            val bytes = luaStringBytes(arg)
            return LuaValue.valueOf(Base64.getEncoder().encodeToString(bytes))
        }
    })
    t.set("decode", object : OneArgFunction() {
        override fun call(arg: LuaValue): LuaValue {
            val decoded = Base64.getDecoder().decode(arg.tojstring())
            return LuaString.valueOf(decoded)
        }
    })
    return t
}

// -------- dkjson --------

private val gson = GsonBuilder().serializeNulls().create()
private val gsonPretty = GsonBuilder().serializeNulls().setPrettyPrinting().create()

private fun makeDkjson(): LuaTable {
    val t = LuaTable()
    t.set("encode", object : VarArgFunction() {
        override fun invoke(args: Varargs): Varargs {
            val value = args.arg(1)
            val opts = args.arg(2)
            val pretty = !opts.isnil() && opts.get("indent").toboolean()
            return LuaValue.valueOf(encodeJson(value, pretty))
        }
    })
    t.set("decode", object : VarArgFunction() {
        override fun invoke(args: Varargs): Varargs {
            val str = args.arg(1).tojstring()
            return try {
                val parsed = jsonToLua(JsonParser.parseString(str))
                LuaValue.varargsOf(parsed, LuaValue.valueOf(str.length + 1), LuaValue.NIL)
            } catch (e: Exception) {
                LuaValue.varargsOf(LuaValue.NIL, LuaValue.ONE, LuaValue.valueOf(e.message ?: "decode error"))
            }
        }
    })
    return t
}

private fun encodeJson(v: LuaValue, pretty: Boolean): String {
    val javaObj = luaToJava(v)
    return if (pretty) gsonPretty.toJson(javaObj) else gson.toJson(javaObj)
}

private fun luaToJava(v: LuaValue): Any? = when {
    v.isnil() -> null
    v.isboolean() -> v.toboolean()
    v.isint() -> v.toint().toLong()
    v.isnumber() -> v.todouble()
    v.isstring() -> v.tojstring()
    v.istable() -> {
        val tbl = v.checktable()
        if (isLuaArray(tbl)) {
            val list = mutableListOf<Any?>()
            var i = 1
            while (true) {
                val item = tbl.get(i)
                if (item.isnil()) break
                list.add(luaToJava(item))
                i++
            }
            list
        } else {
            val map = linkedMapOf<String, Any?>()
            for (k in tbl.keys()) map[k.tojstring()] = luaToJava(tbl.get(k))
            map
        }
    }
    else -> v.tojstring()
}

private fun isLuaArray(t: LuaTable): Boolean {
    val keys = t.keys()
    if (keys.isEmpty()) return true
    val ints = mutableListOf<Int>()
    for (k in keys) {
        if (!k.isint()) return false
        ints.add(k.toint())
    }
    ints.sort()
    if (ints.first() != 1) return false
    for (i in 1 until ints.size) if (ints[i] != ints[i - 1] + 1) return false
    return true
}

private fun jsonToLua(e: JsonElement): LuaValue = when {
    e.isJsonNull -> LuaValue.NIL
    e.isJsonPrimitive -> {
        val p = e.asJsonPrimitive
        when {
            p.isBoolean -> LuaValue.valueOf(p.asBoolean)
            p.isNumber -> {
                val d = p.asDouble
                if (d == d.toLong().toDouble() && d >= Int.MIN_VALUE.toDouble() && d <= Int.MAX_VALUE.toDouble())
                    LuaValue.valueOf(d.toInt())
                else LuaValue.valueOf(d)
            }
            p.isString -> LuaValue.valueOf(p.asString)
            else -> LuaValue.NIL
        }
    }
    e.isJsonArray -> {
        val t = LuaTable()
        e.asJsonArray.forEachIndexed { i, item -> t.set(i + 1, jsonToLua(item)) }
        t
    }
    e.isJsonObject -> {
        val t = LuaTable()
        for ((k, v) in e.asJsonObject.entrySet()) t.set(k, jsonToLua(v))
        t
    }
    else -> LuaValue.NIL
}

// -------- ltn12 --------

private fun makeLtn12(): LuaTable {
    val ltn12 = LuaTable()

    val source = LuaTable()
    source.set("string", object : OneArgFunction() {
        override fun call(s: LuaValue): LuaValue {
            val bytes = luaStringBytes(s)
            var done = false
            return object : ZeroArgFunction() {
                override fun call(): LuaValue {
                    if (done) return LuaValue.NIL
                    done = true
                    return LuaString.valueOf(bytes)
                }
            }
        }
    })
    ltn12.set("source", source)

    val sink = LuaTable()
    sink.set("table", object : OneArgFunction() {
        override fun call(t: LuaValue): LuaValue {
            val tbl = t.checktable()
            return object : VarArgFunction() {
                override fun invoke(args: Varargs): Varargs {
                    val chunk = args.arg(1)
                    if (chunk.isnil()) return LuaValue.ONE
                    tbl.set(tbl.length() + 1, chunk)
                    return LuaValue.ONE
                }
            }
        }
    })
    ltn12.set("sink", sink)

    // pump.all(src, snk) — drains src into snk; returns 1 on success
    val pump = LuaTable()
    pump.set("all", object : VarArgFunction() {
        override fun invoke(args: Varargs): Varargs {
            val src = args.arg(1)
            val snk = args.arg(2)
            while (true) {
                val chunk = src.call()
                if (chunk.isnil()) {
                    snk.call(LuaValue.NIL)
                    return LuaValue.ONE
                }
                snk.call(chunk)
            }
            @Suppress("UNREACHABLE_CODE")
            return LuaValue.ONE
        }
    })
    ltn12.set("pump", pump)

    return ltn12
}

// -------- socket.http --------

private val httpClient: HttpClient = HttpClient.newBuilder()
    .connectTimeout(Duration.ofSeconds(30))
    .build()

private fun makeSocketHttp(): LuaTable {
    val t = LuaTable()
    t.set("request", object : VarArgFunction() {
        override fun invoke(args: Varargs): Varargs {
            val first = args.arg(1)
            return try {
                if (first.isstring()) doSimpleGet(first.tojstring())
                else if (first.istable()) doTableRequest(first.checktable())
                else LuaValue.varargsOf(LuaValue.NIL, LuaValue.valueOf("invalid args to http.request"))
            } catch (e: Exception) {
                LuaValue.varargsOf(LuaValue.NIL, LuaValue.valueOf(e.message ?: e.javaClass.simpleName))
            }
        }
    })
    return t
}

private fun doSimpleGet(url: String): Varargs {
    val req = HttpRequest.newBuilder(URI.create(url)).GET().build()
    val resp = httpClient.send(req, HttpResponse.BodyHandlers.ofByteArray())
    val body = LuaString.valueOf(resp.body())
    val headersTbl = headersToTable(resp.headers().map())
    return LuaValue.varargsOf(arrayOf(body, LuaValue.valueOf(resp.statusCode()), headersTbl, LuaValue.valueOf("HTTP/1.1 ${resp.statusCode()}")))
}

private fun doTableRequest(opts: LuaTable): Varargs {
    val url = opts.get("url").tojstring()
    val method = if (opts.get("method").isnil()) "GET" else opts.get("method").tojstring().uppercase()
    val builder = HttpRequest.newBuilder(URI.create(url))

    val headersLua = opts.get("headers")
    if (!headersLua.isnil()) {
        val tbl = headersLua.checktable()
        for (k in tbl.keys()) {
            val name = k.tojstring()
            // HttpClient forbids setting these headers explicitly; it manages them itself.
            if (name.equals("content-length", ignoreCase = true) || name.equals("host", ignoreCase = true)) continue
            builder.header(name, tbl.get(k).tojstring())
        }
    }

    val bodyBytes: ByteArray = run {
        val src = opts.get("source")
        if (src.isnil() || src.isfunction().not()) ByteArray(0) else pumpSourceToBytes(src)
    }

    when (method) {
        "GET" -> builder.GET()
        "DELETE" -> builder.DELETE()
        else -> builder.method(method, HttpRequest.BodyPublishers.ofByteArray(bodyBytes))
    }

    val resp = httpClient.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray())

    // Pump response body into sink, if provided.
    val sink = opts.get("sink")
    if (!sink.isnil() && sink.isfunction()) {
        sink.call(LuaString.valueOf(resp.body()))
        sink.call(LuaValue.NIL)
    }

    val headersTbl = headersToTable(resp.headers().map())
    return LuaValue.varargsOf(
        arrayOf(
            LuaValue.ONE,
            LuaValue.valueOf(resp.statusCode()),
            headersTbl,
            LuaValue.valueOf("HTTP/1.1 ${resp.statusCode()}"),
        ),
    )
}

private fun pumpSourceToBytes(source: LuaValue): ByteArray {
    val baos = ByteArrayOutputStream()
    while (true) {
        val chunk = source.call()
        if (chunk.isnil()) break
        baos.write(luaStringBytes(chunk))
    }
    return baos.toByteArray()
}

private fun headersToTable(headers: Map<String, List<String>>): LuaTable {
    val t = LuaTable()
    for ((name, values) in headers) {
        t.set(name.lowercase(), LuaValue.valueOf(values.joinToString(", ")))
    }
    return t
}

// -------- helpers --------

private fun luaStringBytes(v: LuaValue): ByteArray {
    if (v is LuaString) {
        return v.m_bytes.copyOfRange(v.m_offset, v.m_offset + v.m_length)
    }
    return v.tojstring().toByteArray(Charsets.UTF_8)
}
