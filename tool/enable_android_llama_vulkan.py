"""Enable the vendored llama.cpp Vulkan backend in the pinned Android plugin.

Run after `flutter pub get` and before any Android Gradle build.
The package's published CMakeLists hard-disables GGML_VULKAN despite exposing
GPU layers at runtime. Fail closed if its layout/version changes.
This patches only the build worker's pub cache, never the source repository.
"""
import json
from pathlib import Path
import shutil
from urllib.parse import urlparse, unquote

ROOT = Path(__file__).resolve().parent.parent
packages = ROOT / ".dart_tool/package_config.json"
if not packages.is_file():
    raise SystemExit("Run flutter pub get before enabling Vulkan")
config = json.loads(packages.read_text(encoding="utf-8"))
entry = next((p for p in config["packages"]
              if p["name"] == "llama_flutter_android"), None)
if entry is None:
    raise SystemExit("llama_flutter_android is missing from package_config.json")

uri = entry["rootUri"]
if uri.startswith("file://"):
    package = Path(unquote(urlparse(uri).path)).resolve()
elif "://" not in uri:
    package = (packages.parent / unquote(uri)).resolve()
else:
    raise SystemExit("Unsupported package URI: " + uri)

pubspec = package / "pubspec.yaml"
if not pubspec.is_file() or "version: 0.2.6" not in pubspec.read_text(encoding="utf-8"):
    raise SystemExit("Unverified llama_flutter_android version; refusing Vulkan patch")
cmake = package / "android/CMakeLists.txt"
gradle = package / "android/build.gradle.kts"
if not cmake.is_file() or not gradle.is_file():
    raise SystemExit("Native plugin build files missing")

glslc = shutil.which("glslc")
vulkan_include = Path("/usr/include")
if not glslc or not (vulkan_include / "vulkan/vulkan.hpp").is_file():
    raise SystemExit("Vulkan build dependencies missing: install libvulkan-dev glslc")
spirv_configs = [
    Path("/usr/share/cmake/SPIRV-Headers"),
    Path("/usr/lib/x86_64-linux-gnu/cmake/SPIRV-Headers"),
    Path("/usr/lib/cmake/SPIRV-Headers"),
]
spirv_dir = next((p for p in spirv_configs
                  if (p / "SPIRV-HeadersConfig.cmake").is_file()), None)
if spirv_dir is None:
    raise SystemExit("SPIRV-Headers cmake config missing: install spirv-headers")

cmake_text = cmake.read_text(encoding="utf-8")
from_line = 'set(GGML_VULKAN OFF CACHE BOOL "Enable Vulkan GPU backend")'
to_line = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan GPU backend" FORCE)'
if from_line in cmake_text:
    cmake.write_text(cmake_text.replace(from_line, to_line), encoding="utf-8")
elif to_line not in cmake_text:
    raise SystemExit("Plugin Vulkan CMake option changed; refusing blind patch")

gradle_text = gradle.read_text(encoding="utf-8")
marker = '"-DGGML_DOTPROD=ON"'
extra = f'''"-DGGML_VULKAN=ON",
                    "-DVulkan_INCLUDE_DIR={vulkan_include}",
                    "-DVulkan_GLSLC_EXECUTABLE={glslc}",
                    "-DSPIRV-Headers_DIR={spirv_dir}"'''
if "-DVulkan_GLSLC_EXECUTABLE=" not in gradle_text:
    if marker not in gradle_text:
        raise SystemExit("Plugin CMake arguments changed; refusing blind patch")
    gradle_text = gradle_text.replace(marker, marker + ",\n                    " + extra, 1)
    gradle.write_text(gradle_text, encoding="utf-8")

print("Vulkan backend enabled in llama_flutter_android 0.2.6; "
      f"glslc={glslc} spirv={spirv_dir}")
