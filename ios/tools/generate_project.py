#!/usr/bin/env python3
"""Regenerate ios/Framewise.xcodeproj/project.pbxproj in the classic format.

The project was originally written using Xcode 16's synchronized folder
groups, which keep the file list in sync automatically but make the project
unopenable on Xcode 15 and earlier. This emits the classic format instead:
every file listed explicitly, objectVersion 56, which every Xcode from 13
through 16+ can open.

The tradeoff is that the file list is now a snapshot. Re-run this script
after adding, renaming or deleting a source file:

    python3 ios/tools/generate_project.py
"""

import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "Framewise"
SRC = os.path.join(ROOT, APP)

# Build settings live here so the generator stays the single source of truth.
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"
# Must be unique across all of Apple's developer accounts. `com.example.*` is
# a placeholder others have already registered, so it fails to provision.
BUNDLE_ID = "com.fordhamwong.framewise"

USAGE = {
    "NSCameraUsageDescription":
        "Framewise needs the camera to show you the live frame, coach your "
        "composition, and take the photo.",
    "NSPhotoLibraryAddUsageDescription":
        "Framewise saves your finished photos straight into your Photos library.",
    "NSPhotoLibraryUsageDescription":
        "Framewise saves your finished photos into your Photos library and "
        "keeps them together in a Framewise album.",
    "NSLocationWhenInUseUsageDescription":
        "Framewise uses your location only to work out the sun's position, so "
        "it can tell you when golden hour starts and which way the light is "
        "coming from. Location is never stored or uploaded.",
}


def uid(*parts):
    """Deterministic 24-hex-character object id, so regenerating the project
    produces a stable diff rather than churning every id."""
    digest = hashlib.md5("::".join(parts).encode()).hexdigest()
    return digest[:24].upper()


def collect():
    """Returns (subdirectory -> [filenames]) plus the files at the app root."""
    tree, root_files = {}, []
    for entry in sorted(os.listdir(SRC)):
        full = os.path.join(SRC, entry)
        if entry.endswith(".swift"):
            root_files.append(entry)
        elif entry.endswith(".xcassets"):
            root_files.append(entry)
        elif os.path.isdir(full):
            swifts = sorted(f for f in os.listdir(full) if f.endswith(".swift"))
            if swifts:
                tree[entry] = swifts
    return tree, root_files


def file_type(name):
    if name.endswith(".swift"):
        return "sourcecode.swift"
    if name.endswith(".xcassets"):
        return "folder.assetcatalog"
    return "text"


def main():
    tree, root_files = collect()

    # (group path or None, filename) for every file in the target.
    entries = [(None, f) for f in root_files]
    for group, files in tree.items():
        entries += [(group, f) for f in files]

    compiled = [(g, f) for g, f in entries if f.endswith(".swift")]
    resources = [(g, f) for g, f in entries if f.endswith(".xcassets")]

    def ref(group, name):
        return uid("ref", group or "", name)

    def build(group, name):
        return uid("build", group or "", name)

    ids = {
        "project": uid("project"),
        "target": uid("target"),
        "product": uid("product"),
        "mainGroup": uid("group", "main"),
        "productsGroup": uid("group", "products"),
        "appGroup": uid("group", APP),
        "sources": uid("phase", "sources"),
        "frameworks": uid("phase", "frameworks"),
        "resources": uid("phase", "resources"),
        "projectCfg": uid("cfglist", "project"),
        "targetCfg": uid("cfglist", "target"),
        "projDebug": uid("cfg", "project", "Debug"),
        "projRelease": uid("cfg", "project", "Release"),
        "tgtDebug": uid("cfg", "target", "Debug"),
        "tgtRelease": uid("cfg", "target", "Release"),
    }

    out = []
    w = out.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    w("\n/* Begin PBXBuildFile section */")
    for group, name in compiled + resources:
        phase = "Sources" if name.endswith(".swift") else "Resources"
        w(f"\t\t{build(group, name)} /* {name} in {phase} */ = "
          f"{{isa = PBXBuildFile; fileRef = {ref(group, name)} /* {name} */; }};")
    w("/* End PBXBuildFile section */")

    w("\n/* Begin PBXFileReference section */")
    w(f"\t\t{ids['product']} /* {APP}.app */ = {{isa = PBXFileReference; "
      f"explicitFileType = wrapper.application; includeInIndex = 0; "
      f"path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for group, name in entries:
        w(f"\t\t{ref(group, name)} /* {name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = {file_type(name)}; path = {name}; "
          f"sourceTree = \"<group>\"; }};")
    w("/* End PBXFileReference section */")

    def phase(pid, isa, label, members):
        w(f"\n/* Begin {isa} section */")
        w(f"\t\t{pid} /* {label} */ = {{")
        w(f"\t\t\tisa = {isa};")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for group, name in members:
            w(f"\t\t\t\t{build(group, name)} /* {name} in {label} */,")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
        w(f"/* End {isa} section */")

    phase(ids["frameworks"], "PBXFrameworksBuildPhase", "Frameworks", [])

    w("\n/* Begin PBXGroup section */")
    w(f"\t\t{ids['mainGroup']} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{ids['appGroup']} /* {APP} */,")
    w(f"\t\t\t\t{ids['productsGroup']} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{ids['productsGroup']} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{ids['product']} /* {APP}.app */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{ids['appGroup']} /* {APP} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for name in root_files:
        if name.endswith(".swift"):
            w(f"\t\t\t\t{ref(None, name)} /* {name} */,")
    for group in tree:
        w(f"\t\t\t\t{uid('group', group)} /* {group} */,")
    for name in root_files:
        if not name.endswith(".swift"):
            w(f"\t\t\t\t{ref(None, name)} /* {name} */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = {APP};")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    for group, files in tree.items():
        w(f"\t\t{uid('group', group)} /* {group} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for name in files:
            w(f"\t\t\t\t{ref(group, name)} /* {name} */,")
        w("\t\t\t);")
        w(f"\t\t\tpath = {group};")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")
    w("/* End PBXGroup section */")

    w("\n/* Begin PBXNativeTarget section */")
    w(f"\t\t{ids['target']} /* {APP} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {ids['targetCfg']} /* Build configuration list for PBXNativeTarget \"{APP}\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{ids['sources']} /* Sources */,")
    w(f"\t\t\t\t{ids['frameworks']} /* Frameworks */,")
    w(f"\t\t\t\t{ids['resources']} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w(f"\t\t\tname = {APP};")
    w(f"\t\t\tproductName = {APP};")
    w(f"\t\t\tproductReference = {ids['product']} /* {APP}.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    w("\n/* Begin PBXProject section */")
    w(f"\t\t{ids['project']} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    w("\t\t\t\tLastUpgradeCheck = 1500;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{ids['target']} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {ids['projectCfg']} /* Build configuration list for PBXProject \"{APP}\" */;")
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {ids['mainGroup']};")
    w(f"\t\t\tproductRefGroup = {ids['productsGroup']} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{ids['target']} /* {APP} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    phase(ids["resources"], "PBXResourcesBuildPhase", "Resources", resources)
    phase(ids["sources"], "PBXSourcesBuildPhase", "Sources", compiled)

    shared = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
    }
    debug_only = {
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"",
    }
    release_only = {
        "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-O\"",
        "VALIDATE_PRODUCT": "YES",
    }
    target_shared = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UIRequiresFullScreen": "YES",
        "INFOPLIST_KEY_UIStatusBarHidden": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "\"$(TARGET_NAME)\"",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1",
    }
    for key, text in USAGE.items():
        target_shared[f"INFOPLIST_KEY_{key}"] = '"' + text.replace('"', '\\"') + '"'

    def config(cid, name, settings):
        w(f"\t\t{cid} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for key in sorted(settings):
            w(f"\t\t\t\t{key} = {settings[key]};")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")

    w("\n/* Begin XCBuildConfiguration section */")
    config(ids["projDebug"], "Debug", {**shared, **debug_only})
    config(ids["projRelease"], "Release", {**shared, **release_only})
    config(ids["tgtDebug"], "Debug", dict(target_shared))
    config(ids["tgtRelease"], "Release", dict(target_shared))
    w("/* End XCBuildConfiguration section */")

    w("\n/* Begin XCConfigurationList section */")
    for cid, label, debug, release in (
        (ids["projectCfg"], f"Build configuration list for PBXProject \"{APP}\"",
         ids["projDebug"], ids["projRelease"]),
        (ids["targetCfg"], f"Build configuration list for PBXNativeTarget \"{APP}\"",
         ids["tgtDebug"], ids["tgtRelease"]),
    ):
        w(f"\t\t{cid} /* {label} */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{debug} /* Debug */,")
        w(f"\t\t\t\t{release} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")

    w("\t};")
    w(f"\trootObject = {ids['project']} /* Project object */;")
    w("}")

    path = os.path.join(ROOT, f"{APP}.xcodeproj", "project.pbxproj")
    with open(path, "w") as handle:
        handle.write("\n".join(out) + "\n")

    print(f"wrote {path}")
    print(f"  {len(compiled)} source files, {len(resources)} resource(s)")
    print(f"  objectVersion 56 — opens in Xcode 13 and later")


if __name__ == "__main__":
    main()
