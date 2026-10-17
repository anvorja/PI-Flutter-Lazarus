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
subprojects {
    // Algunos plugins (p. ej. flutter_pcm_sound) declaran un compileSdk antiguo
    // (33) que rompe con dependencias androidx que exigen API 34+. Forzamos el
    // compileSdk de todos los módulos Android a 36 (vía reflexión, sin depender de
    // tipos de AGP en este script raíz). Se registra ANTES de evaluationDependsOn
    // para que el proyecto aún no esté evaluado al añadir el hook.
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass
                    .getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(androidExt, 36)
            }
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
