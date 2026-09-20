"""Compile the actual production StorageDownloadSession with minimal JVM stubs.

Uses an installed kotlinc, or Kotlin compiler jars already in the Gradle cache.
No downloads, Android runtime, production edits, or added Gradle dependencies.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
APP = HERE.parents[1]
SOURCE = APP / "android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt"

STUBS = """
@file:Suppress("UNUSED_PARAMETER")
object Log {
    fun w(tag: String, message: String) {}
    fun getStackTraceString(error: Throwable) = error.stackTraceToString()
}
%s
class TestHandler {
    fun removeCallbacks(task: Runnable) {}
    fun postDelayed(task: Runnable, delay: Long) {}
    fun post(task: Runnable) { task.run() }
}
class OmiBleManager {
    companion object {
        private const val TAG = "test"
    }
    val mainHandler = TestHandler()
    val activeDownloads = java.util.concurrent.ConcurrentHashMap<String, StorageDownloadSession>()
    fun applyConnectionPriority(address: String) {}
%s
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default=shutil.which("java"))
    parser.add_argument("--kotlin-version", default="2.1.0", help="Compiler version in local Gradle cache")
    parser.add_argument("--notifications", action="store_true", help="Test actual notification subscription methods")
    args = parser.parse_args()
    java = args.java
    if not java and os.environ.get("JAVA_HOME"):
        java = str(Path(os.environ["JAVA_HOME"]) / "bin" / ("java.exe" if os.name == "nt" else "java"))
    if not java:
        parser.error("Supply --java PATH or set JAVA_HOME / PATH to a JDK")

    source = SOURCE.read_text(encoding="utf-8")
    # This inner class is the last member. Fail if that seam moves, rather than
    # silently executing a copied/reimplemented packet receiver.
    match = re.search(r"(    inner class StorageDownloadSession\(.*\n    })\s*\n}\s*$", source, re.S)
    if not match:
        raise RuntimeError("Production session extraction seam changed; review the harness")

    pigeon = SOURCE.with_name("PigeonCommunicator.g.kt").read_text(encoding="utf-8")
    # Execute the generated error envelope too; do not substitute an invented mapping.
    utils = pigeon[pigeon.index("private object PigeonCommunicatorPigeonUtils"):pigeon.index("/**")]
    error = re.search(r"class FlutterError \(.*?\) : Throwable\(\)", pigeon, re.S)
    if not error:
        raise RuntimeError("Pigeon FlutterError extraction seam changed")
    bridge = utils.replace("private object", "object", 1) + error.group()

    cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"

    def jar(group, name, version=None):
        root = cache / group / name
        matches = sorted(root.glob(f"{version or '*'}/*/{name}-*.jar"))
        if not matches:
            raise RuntimeError(f"Missing cached {group}:{name}:{version or '*'}; install Kotlin or build the app first")
        return str(matches[-1])

    kotlinc = shutil.which("kotlinc")
    with tempfile.TemporaryDirectory(prefix="storage-session-compile-") as work:
        work = Path(work)
        generated = work / "OmiBleManager.kt"
        if args.notifications:
            subscription = source[source.index("    private class PendingSubscription"):source.index("    fun unsubscribeCharacteristic")]
            cleanup = source[source.index("    private fun failPendingSubscriptions"):source.index("    fun cleanupPeripheral")]
            descriptor = re.search(r"        override fun onDescriptorWrite\(.*?\n        }", source, re.S)
            if not descriptor:
                raise RuntimeError("Descriptor callback extraction seam changed")
            template = (HERE / "NotificationSubscriptionStubs.kt").read_text(encoding="utf-8")
            generated.write_text(template.replace("// PRODUCTION_SUBSCRIPTIONS", subscription)
                                 .replace("// PRODUCTION_CLEANUP", cleanup)
                                 .replace("// PRODUCTION_DESCRIPTOR", descriptor.group().replace("override fun", "fun", 1)), encoding="utf-8")
        else:
            generated.write_text(STUBS % (bridge, match.group(1)), encoding="utf-8")
        output = work / "tests.jar"
        tests = HERE / ("NotificationSubscriptionTest.kt" if args.notifications else "StorageDownloadSessionTest.kt")
        if kotlinc:
            subprocess.run([kotlinc, str(generated), str(tests), "-include-runtime", "-d", str(output)], check=True)
            runtime = str(output)
        else:
            libs = [jar("org.jetbrains.kotlin", name, args.kotlin_version) for name in (
                "kotlin-compiler-embeddable", "kotlin-stdlib", "kotlin-script-runtime", "kotlin-reflect")]
            libs += [jar("org.jetbrains.intellij.deps", "trove4j"),
                     jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm"),
                     jar("org.jetbrains", "annotations")]
            classpath = os.pathsep.join(libs)
            subprocess.run([java, "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                            "-no-stdlib", "-no-reflect", "-classpath", classpath,
                            str(generated), str(tests), "-d", str(output)], check=True)
            runtime = os.pathsep.join([str(output), *libs])
        subprocess.run([java, "-cp", runtime, tests.stem + "Kt"], check=True)


if __name__ == "__main__":
    main()
