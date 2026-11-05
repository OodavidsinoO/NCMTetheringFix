# One entry point for local builds and CI. The Gradle task owns the zip layout
# so both paths produce identical bytes.
version := `sed -n 's/^version=//p' module/module.prop`
output := "build/ncm-tethering-fix-" + version + ".zip"

default: package

package:
    ./gradlew packageModule
    sha256sum {{output}}
