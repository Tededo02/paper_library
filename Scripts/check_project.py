#!/usr/bin/env python3
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
project_path = ROOT / "PaperLibrary.xcodeproj/project.pbxproj"
parsed = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(project_path)], check=True, capture_output=True)
project = json.loads(parsed.stdout)
objects = project["objects"]
assert objects[project["rootObject"]]["isa"] == "PBXProject"
assert objects[project["rootObject"]]["developmentRegion"] == "en"
assert objects[project["rootObject"]]["knownRegions"] == ["en", "Base"]
targets = {key: value for key, value in objects.items() if value["isa"] == "PBXNativeTarget"}
assert {target["name"] for target in targets.values()} == {"PaperLibrary", "PaperLibraryTests"}

references = {value["path"] for value in objects.values() if value["isa"] == "PBXFileReference" and value.get("lastKnownFileType") == "sourcecode.swift"}
expected = {str(path.relative_to(ROOT)) for directory in ["PaperLibrary/App", "PaperLibrary/Features", "PaperLibraryTests"] for path in (ROOT / directory).rglob("*.swift")}
assert references == expected, "Regenerate the Xcode project after adding or removing source files"
assert all((ROOT / path).is_file() for path in references)
print(f"PASS: Xcode project references all {len(references)} application and test sources")

for target in targets.values():
    configuration_list = objects[target["buildConfigurationList"]]
    configs = [objects[key] for key in configuration_list["buildConfigurations"]]
    assert {item["name"] for item in configs} == {"Debug", "Release"}
    for config in configs:
        settings = config["buildSettings"]
        assert settings["MACOSX_DEPLOYMENT_TARGET"] == "26.0"
        assert settings["SWIFT_VERSION"] == "6.0"
        assert settings["ONLY_ACTIVE_ARCH"] == "YES"
        if target["name"] == "PaperLibrary":
            assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "local.paperlibrary.app"
            assert settings["INFOPLIST_FILE"] == "PaperLibrary/Info.plist"
            assert settings["ENABLE_APP_SANDBOX"] == "NO"
            assert settings["PAPERLIBRARY_APP_OUTPUT_DIR"] == "$(PROJECT_DIR)/build/release"
            assert settings["TARGET_BUILD_DIR"] == "$(PAPERLIBRARY_APP_OUTPUT_DIR)"
            assert settings["WRAPPER_NAME"] == "Paper Library.app"
            assert objects[target["productReference"]]["path"] == "Paper Library.app"
    products = {objects[key]["productName"] for key in target["packageProductDependencies"]}
    assert products == {"PaperLibraryCore", "PaperLibrarySupport", "PaperLibraryUI"}
print("PASS: Debug and Release share the fixed bundle identifier and local package products")
print("PASS: Both configurations use the single persistent app path")

scheme = ET.parse(ROOT / "PaperLibrary.xcodeproj/xcshareddata/xcschemes/PaperLibrary.xcscheme")
for reference in scheme.findall(".//BuildableReference"):
    assert reference.attrib["BlueprintIdentifier"] in targets
    if targets[reference.attrib["BlueprintIdentifier"]]["name"] == "PaperLibrary":
        assert reference.attrib["BuildableName"] == "Paper Library.app"
assert scheme.find(".//CommandLineArgument").attrib["argument"] == "--demo"
print("PASS: Shared scheme references existing targets and explicitly selects the demo library")

strings_path = ROOT / "PaperLibrary/Support/Resources/en.lproj/Localizable.strings"
subprocess.run(["plutil", "-lint", str(strings_path), str(ROOT / "PaperLibrary/Info.plist")], check=True)
info = plistlib.loads((ROOT / "PaperLibrary/Info.plist").read_bytes())
assert info["CFBundleDevelopmentRegion"] == "en"
assert info["CFBundleLocalizations"] == ["en"]
keys = set(re.findall(r'^"([^"]+)"\s*=', strings_path.read_text(), re.MULTILINE))
swift_files = sorted((ROOT / "PaperLibrary").rglob("*.swift")) + sorted((ROOT / "PaperLibraryTests").rglob("*.swift"))
for path in swift_files:
    for key in re.findall(r'Strings\.text\("([^"\\]+)"\)', path.read_text()):
        assert key in keys, f"Missing localization: {key}"
subprocess.run(["swiftc", "-frontend", "-parse", *map(str, swift_files)], check=True)
print("PASS: Localized literal keys exist and all application/test Swift files parse")
print("Configuration and syntax validation only; this is not an Xcode build or SwiftData type check.")
