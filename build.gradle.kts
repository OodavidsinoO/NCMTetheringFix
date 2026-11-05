// The app_process helper and its hiddenapi stubs are gone: Tethering starts the
// IpServer itself from the USB_STATE broadcast, so nothing needs to run in the
// background. All that remains is packaging the KernelSU/Magisk module zip.
//
// The zip layout is flat: module.prop and the scripts sit at the archive root,
// exactly as /data/adb/modules/<id> expects. Scripts are stored executable so
// the module works even when the installer cannot chmod; customize.sh also
// calls set_perm as a second line of defence.
//
// Timestamps are dropped and file order fixed so the same commit always yields
// the same bytes, which is what makes the published SHA256SUMS meaningful.

plugins {
    base
}

val moduleVersion = providers.fileContents(layout.projectDirectory.file("module/module.prop"))
    .asText
    .map { prop -> prop.lineSequence().first { it.startsWith("version=") }.substringAfter('=').trim() }
    .getOrElse("v0.0.0")

val outputDir = layout.buildDirectory.dir("module")
val zipName = "ncm-tethering-fix-$moduleVersion.zip"

tasks.register<Sync>("stageModule") {
    group = "build"
    description = "Stages the module tree in build/module."
    from(layout.projectDirectory.dir("module")) {
        include("module.prop", "*.sh")
        filePermissions { unix("0755") }
    }
    into(outputDir)
}

tasks.register<Zip>("packageModule") {
    group = "build"
    description = "Builds the flashable KernelSU/Magisk module zip."
    dependsOn("stageModule")
    from(outputDir) {
        // module.prop is data, not a program.
        exclude("module.prop")
        filePermissions { unix("0755") }
    }
    from(outputDir) {
        include("module.prop")
        filePermissions { unix("0644") }
    }
    into("")
    archiveFileName = zipName
    destinationDirectory = layout.buildDirectory
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
    doLast {
        logger.lifecycle("module zip: ${destinationDirectory.get().file(zipName).asFile}")
    }
}
