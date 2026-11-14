#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "PaperLibrary.xcodeproj"
objects = {}


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **fields):
    key = identifier(object_name)
    objects[key] = {"isa": isa, **fields}
    return key


def encode(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        body = "\n".join(f'{indent}\t{json.dumps(str(k))} = {encode(v, level + 1)};' for k, v in value.items())
        return "{\n" + body + "\n" + indent + "}"
    if isinstance(value, list):
        return "(\n" + "\n".join(f"{indent}\t{encode(item, level + 1)}," for item in value) + "\n" + indent + ")"
    return json.dumps(str(value))


def file_reference(path, file_type="sourcecode.swift"):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")


def sources(name, files):
    builds = [add(f"build:{name}:{path}", "PBXBuildFile", fileRef=file_reference(path)) for path in files]
    return add("sources:" + name, "PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")


def configurations(name, settings):
    entries = []
    for configuration in ["Debug", "Release"]:
        merged = {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O"}
        if configuration == "Debug":
            merged["ENABLE_TESTABILITY"] = "YES"
        entries.append(add(f"config:{name}:{configuration}", "XCBuildConfiguration", buildSettings=merged, name=configuration))
    return add("config-list:" + name, "XCConfigurationList", buildConfigurations=entries, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


app_files = sorted(str(path.relative_to(ROOT)) for folder in ["App", "Features"] for path in (ROOT / "PaperLibrary" / folder).rglob("*.swift"))
test_files = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "PaperLibraryTests").glob("*.swift"))
package = add("local-package", "XCLocalSwiftPackageReference", relativePath=".")
core = add("core-product", "XCSwiftPackageProductDependency", package=package, productName="PaperLibraryCore")
support = add("support-product", "XCSwiftPackageProductDependency", package=package, productName="PaperLibrarySupport")
ui = add("ui-product", "XCSwiftPackageProductDependency", package=package, productName="PaperLibraryUI")
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="Paper Library.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="PaperLibraryTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")

base = {
    "MACOSX_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "macosx", "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete", "CLANG_ENABLE_MODULES": "YES", "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": "", "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES", "PRODUCT_NAME": "$(TARGET_NAME)",
    "ONLY_ACTIVE_ARCH": "YES",
}
app_sources = sources("app", app_files)
test_sources = sources("tests", test_files)
icon_reference = file_reference("PaperLibrary/Resources/AppIcon.icns", "image.icns")
app_resources = add("app-resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[add("build:app:icon", "PBXBuildFile", fileRef=icon_reference)], runOnlyForDeploymentPostprocessing="0")
app_frameworks = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[add("link:app:core", "PBXBuildFile", productRef=core), add("link:app:support", "PBXBuildFile", productRef=support), add("link:app:ui", "PBXBuildFile", productRef=ui)], runOnlyForDeploymentPostprocessing="0")
test_frameworks = add("test-frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[add("link:tests:core", "PBXBuildFile", productRef=core), add("link:tests:support", "PBXBuildFile", productRef=support), add("link:tests:ui", "PBXBuildFile", productRef=ui)], runOnlyForDeploymentPostprocessing="0")
app_config = configurations("app", {**base, "INFOPLIST_FILE": "PaperLibrary/Info.plist", "PRODUCT_BUNDLE_IDENTIFIER": "local.paperlibrary.app", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "PAPERLIBRARY_APP_OUTPUT_DIR": "$(PROJECT_DIR)/build/release", "TARGET_BUILD_DIR": "$(PAPERLIBRARY_APP_OUTPUT_DIR)", "WRAPPER_NAME": "Paper Library.app"})
test_config = configurations("tests", {**base, "GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "local.paperlibrary.tests"})
app_target = add("app-target", "PBXNativeTarget", buildConfigurationList=app_config, buildPhases=[app_sources, app_frameworks, app_resources], buildRules=[], dependencies=[], name="PaperLibrary", packageProductDependencies=[core, support, ui], productName="PaperLibrary", productReference=app_product, productType="com.apple.product-type.application")
test_target = add("test-target", "PBXNativeTarget", buildConfigurationList=test_config, buildPhases=[test_sources, test_frameworks], buildRules=[], dependencies=[], name="PaperLibraryTests", packageProductDependencies=[core, support, ui], productName="PaperLibraryTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
product_group = add("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
source_group = add("sources-group", "PBXGroup", children=[file_reference(path) for path in app_files + test_files], name="Sources", sourceTree="<group>")
resource_group = add("resources-group", "PBXGroup", children=[icon_reference], name="Resources", sourceTree="<group>")
main_group = add("main-group", "PBXGroup", children=[source_group, resource_group, product_group], sourceTree="<group>")
project_config = configurations("project", {"MACOSX_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "macosx", "SWIFT_VERSION": "6.0"})
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "2600", "BuildIndependentTargetsInParallel": "YES"}, buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=main_group, packageReferences=[package], productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[app_target, test_target])
PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text(encode({"archiveVersion": "1", "classes": {}, "objectVersion": "60", "objects": objects, "rootObject": project}) + "\n")
scheme_directory = PROJECT / "xcshareddata" / "xcschemes"
scheme_directory.mkdir(parents=True, exist_ok=True)
(scheme_directory / "PaperLibrary.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Paper Library.app" BlueprintName="PaperLibrary" ReferencedContainer="container:PaperLibrary.xcodeproj"/></BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
    <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="PaperLibraryTests.xctest" BlueprintName="PaperLibraryTests" ReferencedContainer="container:PaperLibrary.xcodeproj"/></TestableReference>
  </Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Paper Library.app" BlueprintName="PaperLibrary" ReferencedContainer="container:PaperLibrary.xcodeproj"/></BuildableProductRunnable>
    <CommandLineArguments><CommandLineArgument argument="--demo" isEnabled="YES"/></CommandLineArguments>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Paper Library.app" BlueprintName="PaperLibrary" ReferencedContainer="container:PaperLibrary.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {PROJECT.name}: {len(app_files)} app sources, {len(test_files)} test sources")
