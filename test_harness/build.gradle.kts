plugins {
    alias(libs.plugins.kotlin.jvm)
    application
    id("com.gradleup.shadow") version "8.3.5"
}

repositories {
    mavenCentral()
}

sourceSets {
    main {
        resources.srcDir("../lib")
    }
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

// Self-contained bundle: fat jar + launchers side by side. Unzip anywhere, put the
// folder (or a symlink to runme.sh) on PATH, and run from any working directory.
tasks.register<Zip>("dist") {
    group = "distribution"
    description = "Package the fat jar, runme launchers and run_script test runners into build/dist"
    val shadowJar = tasks.named<Jar>("shadowJar")
    dependsOn(shadowJar)
    archiveFileName.set("plugin_test_harness.zip")
    destinationDirectory.set(layout.buildDirectory.dir("dist"))
    into("plugin_test_harness") {
        from(shadowJar.flatMap { it.archiveFile })
        from("runme.sh") { filePermissions { unix("rwxr-xr-x") } }
        from("runme.bat")
        from("run_script.sh") { filePermissions { unix("rwxr-xr-x") } }
        from("run_script.bat")
        from("settings-overrides.json") { rename { "settings.json" } }
        into("scripts") {
            from("../examples") { include("*.lua") }
        }
    }
}
