plugins {
    alias(libs.plugins.kotlin.jvm)
    application
    id("com.gradleup.shadow") version "8.3.5"
}

repositories {
    mavenCentral()
}

dependencies {
    implementation(libs.luaj.jse)
    implementation(libs.gson)
    implementation(libs.logback.classic)
}

kotlin {
    jvmToolchain(17)
}

application {
    mainClass.set("com.github.berkeleysquare.lua.LuaRunnerKt")
}

tasks.register<JavaExec>("runLua") {
    group = "application"
    description = "Run a Lua script against the mock PluginBridge"
    mainClass.set("com.github.berkeleysquare.lua.LuaRunnerKt")
    classpath = sourceSets["main"].runtimeClasspath
    val scriptArg = providers.gradleProperty("luaScript").orNull
    if (scriptArg != null) args(scriptArg)
    val inputArg = providers.gradleProperty("luaInput").orNull
    if (inputArg != null) systemProperty("luaInput", inputArg)
    val outputArg = providers.gradleProperty("luaOutput").orNull
    if (outputArg != null) systemProperty("luaOutput", outputArg)
    val settingsArg = providers.gradleProperty("luaSettings").orNull
    if (settingsArg != null) systemProperty("luaSettings", settingsArg)
    val clipArg = providers.gradleProperty("luaClip").orNull
    if (clipArg != null) systemProperty("luaClip", clipArg)
    environment("PATH", "/opt/homebrew/bin:" + System.getenv("PATH"))
    standardInput = System.`in`
}
