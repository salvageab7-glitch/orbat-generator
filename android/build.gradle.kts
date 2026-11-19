allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 统一抬升插件子项目的 compileSdk 到 36：
// file_picker 等插件自带 compileSdk 34，而其依赖（flutter_plugin_android_lifecycle）
// 要求宿主 compileSdk >= 36，若不抬升会在 checkDebugAarMetadata 报错。
// 用反射避免对 AGP 类的直接依赖（各 AGP 版本 API 有差异）。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        try {
            androidExt.javaClass
                .getMethod("setCompileSdkVersion", Integer.TYPE)
                .invoke(androidExt, 36)
        } catch (_: Exception) {
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
