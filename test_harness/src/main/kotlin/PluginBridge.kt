package com.github.berkeleysquare

import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.slf4j.Logger
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse as JdkHttpResponse
import java.time.Duration

/*********
 * Match the interface of the rio object in the Lua scripts, but with mock implementations for testing.
 * Should include all the functions in escapepod/archiveviewer/PluginBridge.kt
 * And all the globals in escapepod/archiveviewer/PluginServiceImpl.kt
 */

@Suppress("unused", "FunctionName")
class PluginBridge(
    private val fileName: String,
    private val logger: Logger,
) {
    private val httpClient: HttpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(30))
        .build()

    fun gpu_exec(command: String): Int {
        logger.info("[mock gpu_exec] $command")
        return 0
    }

    fun save_ai_metadata(metadata: LuaValue) {
        val map = mutableMapOf<String, String>()
        if (metadata is LuaTable) {
            val keys = metadata.keys()
            for (k in keys) map[k.tojstring()] = metadata.get(k).tojstring()
        }
        logger.info("[mock save_ai_metadata] $fileName: $map")
    }

    fun save_technical_metadata(metadata: LuaValue) {
        val map = mutableMapOf<String, String>()
        if (metadata is LuaTable) {
            val keys = metadata.keys()
            for (k in keys) map[k.tojstring()] = metadata.get(k).tojstring()
        }
        logger.info("[mock save_technical_metadata] $fileName: $map")
    }

    fun save_transcription(text: String) {
        logger.info("[mock save_transcription] $fileName: $text")
    }

    fun log_debug(message: String) = logger.debug("$fileName: $message")

    fun log_info(message: String) = logger.info("$fileName: $message")

    fun log_warn(message: String) = logger.warn("$fileName: $message")

    fun log_error(message: String) = logger.error("$fileName: $message")

    fun register_thumbnail(thumbnailName: String) {
        logger.info("[mock register_thumbnail] $fileName -> $thumbnailName")
    }

    fun register_proxy(proxyName: String) {
        logger.info("[mock register_proxy] $fileName -> $proxyName")
    }

    fun register_preview(previewName: String) {
        logger.info("[mock register_preview] $fileName -> $previewName")
    }

    fun register_sidecar(sidecarName: String) {
        logger.info("[mock register_sidecar] $fileName -> $sidecarName")
    }

    fun product_status(
        product: String,
        status: String,
        m: String?,
    ) {
        logger.info("[mock product_status] $fileName: $product -> $status: $m")
    }

    fun save_status(
        status: String,
        m: String?,
    ) {
        logger.info("[mock save_status] $fileName: $status: $m")
    }

    fun http_get(url: String): LuaTable = executeHttp(url, "http_get") {
        HttpRequest.newBuilder(URI.create(url)).GET().build()
    }

    fun http_post(url: String, body: String): LuaTable = executeHttp(url, "http_post") {
        HttpRequest.newBuilder(URI.create(url))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build()
    }

    fun http_put(url: String, body: String): LuaTable = executeHttp(url, "http_put") {
        HttpRequest.newBuilder(URI.create(url))
            .header("Content-Type", "application/json")
            .PUT(HttpRequest.BodyPublishers.ofString(body))
            .build()
    }

    fun http_patch(url: String, body: String): LuaTable = executeHttp(url, "http_patch") {
        HttpRequest.newBuilder(URI.create(url))
            .header("Content-Type", "application/json")
            .method("PATCH", HttpRequest.BodyPublishers.ofString(body))
            .build()
    }

    fun http_delete(url: String): LuaTable = executeHttp(url, "http_delete") {
        HttpRequest.newBuilder(URI.create(url)).DELETE().build()
    }

    fun http_head(url: String): LuaTable = executeHttp(url, "http_head") {
        HttpRequest.newBuilder(URI.create(url))
            .method("HEAD", HttpRequest.BodyPublishers.noBody())
            .build()
    }

    fun http_options(url: String): LuaTable = executeHttp(url, "http_options") {
        HttpRequest.newBuilder(URI.create(url))
            .method("OPTIONS", HttpRequest.BodyPublishers.noBody())
            .build()
    }

    private fun executeHttp(url: String, logLabel: String, buildRequest: () -> HttpRequest): LuaTable =
        try {
            val response = httpClient.send(buildRequest(), JdkHttpResponse.BodyHandlers.ofString())
            val headers = response.headers().map().mapValues { it.value.joinToString(", ") }
            buildResponseTable(response.statusCode(), response.body() ?: "", headers)
        } catch (e: Exception) {
            logger.error("$logLabel failed for $url: ${e.message}")
            buildResponseTable(0, "", emptyMap())
        }

    private fun buildResponseTable(status: Int, body: String, headers: Map<String, String>): LuaTable {
        val t = LuaTable()
        t.set("status", LuaValue.valueOf(status))
        t.set("body", LuaValue.valueOf(body))
        val h = LuaTable()
        for ((k, v) in headers) h.set(k.lowercase(), LuaValue.valueOf(v))
        t.set("headers", h)
        return t
    }

    fun exec(cmd: String): String? {
        val isWindows = System.getProperty("os.name").startsWith("Windows")
        val errFile = File.createTempFile("rio-exec", ".err")
        var batFile: File? = null
        return try {
            // On Windows, ProcessBuilder quotes the command argument and escapes inner "
            // as \", which cmd.exe does not recognise as an escape — it mangles paths.
            // Writing to a .bat file sidesteps this: the bat path has no inner quotes, so
            // ProcessBuilder's quoting works, and cmd.exe reads the command verbatim.
            val p = if (isWindows) {
                batFile = File.createTempFile("rio-exec", ".bat").also {
                    it.writeText("@echo off\r\n$cmd\r\n")
                }
                ProcessBuilder("cmd.exe", "/c", batFile!!.absolutePath)
            } else {
                ProcessBuilder("/bin/sh", "-c", cmd)
            }
            p.redirectError(errFile).start().let { proc ->
                val out = proc.inputStream.bufferedReader().use { it.readText() }
                proc.waitFor()
                val err = errFile.readText()
                if (out.isEmpty() && err.isNotEmpty()) {
                    logger.warn("Command failed: $cmd\n$err")
                    null
                } else {
                    out
                }
            }
        } catch (e: Exception) {
            logger.warn("exec failed: $cmd", e)
            null
        } finally {
            errFile.delete()
            batFile?.delete()
        }
    }

}
