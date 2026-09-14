#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 WeldFatigueChecker.xcodeproj/project.pbxproj（Xcode 16 可打开/编译）。
- 递归扫描 WeldFatigueChecker/ 下所有 .swift 作为编译源
- 加入 Model3D/occt_bridge.mm（Objective-C++ 桥接，未启用 USE_OCCT 时为桩，仍可编译）
- 加入 WeldFatigueChecker-Bridging-Header.h（SWIFT_OBJC_BRIDGING_HEADER）
- Resources/ 作为 folder reference 整目录拷贝（标准包 JSON 借此打进 .ipa）
- Info.plist 通过 INFOPLIST_FILE 引用（GENERATE_INFOPLIST_FILE=NO）
- OCCT（.step/.iges）默认不链接：应用可无 OCCT 编译；build_occt_ios.sh + build.sh 会在
  Vendor/OCCT 存在时自动开启 USE_OCCT=1 并链接 libOCCT.a。

用法: python3 tools/gen_xcodeproj.py
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # .../app_ios/native
APP = os.path.join(ROOT, "WeldFatigueChecker")

# 24-hex 唯一 ID 生成器
_counter = [0x100000]
def uid():
    _counter[0] += 1
    return format(_counter[0], "024X")

# ---- 递归收集源文件（相对 APP 的路径）----
swift_files = []
mm_files = []
for dirpath, _, filenames in os.walk(APP):
    for fn in filenames:
        if fn.endswith(".swift"):
            rel = os.path.relpath(os.path.join(dirpath, fn), APP).replace("\\", "/")
            swift_files.append(rel)
        elif fn.endswith(".mm"):
            rel = os.path.relpath(os.path.join(dirpath, fn), APP).replace("\\", "/")
            mm_files.append(rel)
swift_files.sort()
mm_files.sort()

bridging_header = "WeldFatigueChecker-Bridging-Header.h"

# file_refs: rel -> (id, lastKnownFileType)
file_refs = {}
build_files = {}     # rel -> id (sources)
for f in swift_files + mm_files:
    fr = uid(); bf = uid()
    isa = "sourcecode.swift" if f.endswith(".swift") else "sourcecode.cpp.objcpp"
    file_refs[f] = (fr, isa)
    build_files[f] = bf

bh_fr = uid()         # bridging header file ref
res_fr = uid()        # Resources folder reference
bf_res = uid()        # PBXBuildFile for Resources
info_fr = uid()       # Info.plist
app_fr = uid()        # product .app

grp_wfc = uid(); grp_products = uid(); grp_main = uid()
phase_sources = uid(); phase_resources = uid(); phase_frameworks = uid()
cfg_proj_list = uid(); cfg_tgt_list = uid()
cfg_proj_debug = uid(); cfg_proj_rel = uid()
cfg_tgt_debug = uid(); cfg_tgt_rel = uid()
target = uid(); project = uid()

B = []
def L(s): B.append(s)

def file_ref_block(name, fr_id, last_type):
    if last_type == "folder":
        return (f"{fr_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder; "
                f"name = {name}; path = {name}; sourceTree = \"<group>\"; }};")
    elif last_type == "plist":
        return (f"{fr_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
                f"path = {name}; sourceTree = \"<group>\"; }};")
    elif last_type == "c.h":
        return (f"{fr_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; "
                f"path = {name}; sourceTree = \"<group>\"; }};")
    else:
        return (f"{fr_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {last_type}; "
                f"path = {name}; sourceTree = \"<group>\"; }};")

# ---- PBXBuildFile (sources) ----
L("/* Begin PBXBuildFile section */")
for f in swift_files + mm_files:
    bf = build_files[f]; fr = file_refs[f][0]
    L(f"\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f} */; }};")
L("\t\t" + bf_res + " /* Resources */ = {isa = PBXBuildFile; fileRef = " + res_fr + " /* Resources */; };")
L("/* End PBXBuildFile section */")
L("")

# ---- PBXFileReference ----
L("/* Begin PBXFileReference section */")
for f in swift_files + mm_files:
    L("\t\t" + file_ref_block(f, file_refs[f][0], file_refs[f][1]))
L("\t\t" + file_ref_block(bridging_header, bh_fr, "c.h"))
L("\t\t" + file_ref_block("Resources", res_fr, "folder"))
L("\t\t" + file_ref_block("Info.plist", info_fr, "plist"))
L(f"\t\t{app_fr} /* WeldFatigueChecker.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; "
  f"path = WeldFatigueChecker.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
L("/* End PBXFileReference section */")
L("")

# ---- PBXFrameworksBuildPhase (empty; system frameworks autolinked) ----
L("/* Begin PBXFrameworksBuildPhase section */")
L(f"\t\t{phase_frameworks} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; "
  f"files = (\n\t\t); runOnlyForDeploymentPostprocessing = 0; }};")
L("/* End PBXFrameworksBuildPhase section */")
L("")

# ---- PBXGroup ----
L("/* Begin PBXGroup section */")
all_children = ",\n\t\t\t\t".join(file_refs[f][0] for f in swift_files + mm_files)
all_children += ",\n\t\t\t\t" + bh_fr + ",\n\t\t\t\t" + res_fr + ",\n\t\t\t\t" + info_fr
L(f"\t\t{grp_main} = {{isa = PBXGroup; children = (\n\t\t\t\t{grp_wfc},\n\t\t\t\t{grp_products},\n\t\t); "
  f"sourceTree = \"<group>\"; }};")
L(f"\t\t{grp_wfc} /* WeldFatigueChecker */ = {{isa = PBXGroup; children = (\n\t\t\t\t{all_children}\n\t\t); "
  f"path = WeldFatigueChecker; sourceTree = \"<group>\"; }};")
L(f"\t\t{grp_products} /* Products */ = {{isa = PBXGroup; children = (\n\t\t\t\t{app_fr},\n\t\t); "
  f"name = Products; sourceTree = \"<group>\"; }};")
L("/* End PBXGroup section */")
L("")

# ---- PBXNativeTarget ----
L("/* Begin PBXNativeTarget section */")
sources_files = ",\n\t\t\t\t".join(build_files[f] for f in swift_files + mm_files)
L(f"\t\t{target} /* WeldFatigueChecker */ = {{isa = PBXNativeTarget; "
  f"buildConfigurationList = {cfg_tgt_list} /* Build configuration list for PBXNativeTarget \"WeldFatigueChecker\" */; "
  f"buildPhases = (\n\t\t\t\t{phase_sources} /* Sources */,\n\t\t\t\t{phase_frameworks} /* Frameworks */,\n\t\t\t\t{phase_resources} /* Resources */,\n\t\t); "
  f"buildRules = (\n\t\t); dependencies = (\n\t\t); name = WeldFatigueChecker; "
  f"productName = WeldFatigueChecker; productReference = {app_fr} /* WeldFatigueChecker.app */; "
  f"productType = \"com.apple.product-type.application\"; }};")
L("/* End PBXNativeTarget section */")
L("")

# ---- PBXProject ----
L("/* Begin PBXProject section */")
L(f"\t\t{project} /* Project object */ = {{isa = PBXProject; "
  f"attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; "
  f"TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; DevelopmentTeam = \"\"; "
  f"ProvisioningStyle = Automatic; }}; }}; }}; "
  f"buildConfigurationList = {cfg_proj_list} /* Build configuration list for PBXProject \"WeldFatigueChecker\" */; "
  f"compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; "
  f"knownRegions = (\n\t\t\t\ten,\n\t\t\t\t\"zh-Hans\",\n\t\t\t); "
  f"mainGroup = {grp_main}; "
  f"productRefGroup = {grp_products} /* Products */; "
  f"projectDirPath = \"\"; projectRoot = \"\"; "
  f"targets = (\n\t\t\t\t{target} /* WeldFatigueChecker */,\n\t\t); }};")
L("/* End PBXProject section */")
L("")

# ---- PBXResourcesBuildPhase ----
L("/* Begin PBXResourcesBuildPhase section */")
L(f"\t\t{phase_resources} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; "
  f"files = (\n\t\t\t\t{bf_res} /* Resources */,\n\t\t); runOnlyForDeploymentPostprocessing = 0; }};")
L("/* End PBXResourcesBuildPhase section */")
L("")

# ---- PBXSourcesBuildPhase ----
L("/* Begin PBXSourcesBuildPhase section */")
L(f"\t\t{phase_sources} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; "
  f"files = (\n\t\t\t\t{sources_files}\n\t\t); runOnlyForDeploymentPostprocessing = 0; }};")
L("/* End PBXSourcesBuildPhase section */")
L("")

# ---- XCBuildConfiguration (project) ----
L("/* Begin XCBuildConfiguration section */")
L(f"\t\t{cfg_proj_debug} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{ "
  f"ALWAYS_SEARCH_USER_PATHS = NO; "
  f"CLANG_ANALYZER_NONNULL = YES; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; "
  f"COPY_PHASE_STRIP = NO; ENABLE_STRICT_OBJC_MSGSEND = YES; "
  f"GCC_DYNAMIC_NO_PIC = NO; GCC_OPTIMIZATION_LEVEL = 0; GCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\"$(inherited)\",\n\t\t\t); "
  f"IPHONEOS_DEPLOYMENT_TARGET = 18.0; MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE; MTL_FAST_MATH = YES; "
  f"ONLY_ACTIVE_ARCH = YES; SDKROOT = iphoneos; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; "
  f"SWIFT_OPTIMIZATION_LEVEL = \"-Onone\"; }}; name = Debug; }};")
L(f"\t\t{cfg_proj_rel} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{ "
  f"ALWAYS_SEARCH_USER_PATHS = NO; "
  f"CLANG_ANALYZER_NONNULL = YES; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; "
  f"COPY_PHASE_STRIP = NO; ENABLE_NS_ASSERTIONS = NO; "
  f"GCC_OPTIMIZATION_LEVEL = s; IPHONEOS_DEPLOYMENT_TARGET = 18.0; MTL_ENABLE_DEBUG_INFO = NO; "
  f"MTL_FAST_MATH = YES; SDKROOT = iphoneos; SWIFT_COMPILATION_MODE = wholemodule; "
  f"SWIFT_OPTIMIZATION_LEVEL = \"-O\"; VALIDATE_PRODUCT = YES; }}; name = Release; }};")
L("/* End XCBuildConfiguration section */")
L("")

# ---- XCConfigurationList ----
L("/* Begin XCConfigurationList section */")
L(f"\t\t{cfg_proj_list} /* Build configuration list for PBXProject \"WeldFatigueChecker\" */ = {{isa = XCConfigurationList; "
  f"buildConfigurations = (\n\t\t\t\t{cfg_proj_debug} /* Debug */,\n\t\t\t\t{cfg_proj_rel} /* Release */,\n\t\t); "
  f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

# target configs（含桥接头）
tgt_base = (
  "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES; "
  "CODE_SIGN_STYLE = Automatic; "
  "CURRENT_PROJECT_VERSION = 1; "
  "DEVELOPMENT_TEAM = \"\"; "
  "ENABLE_BITCODE = NO; "
  "INSTALL_PATH = /Applications; "
  "GENERATE_INFOPLIST_FILE = NO; "
  "INFOPLIST_FILE = WeldFatigueChecker/Info.plist; "
  "SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; "
  "IPHONEOS_DEPLOYMENT_TARGET = 18.0; "
  "LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\"$(inherited)\",\n\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t); "
  "MARKETING_VERSION = 1.0; "
  "PRODUCT_BUNDLE_IDENTIFIER = com.yourorg.weldfatiguechecker; "
  "PRODUCT_NAME = \"$(TARGET_NAME)\"; "
  "SWIFT_EMIT_LOC_STRINGS = YES; "
  "SWIFT_OBJC_BRIDGING_HEADER = WeldFatigueChecker/WeldFatigueChecker-Bridging-Header.h; "
  "SWIFT_VERSION = 5.0; "
  "TARGETED_DEVICE_FAMILY = \"1,2\"; "
)
L(f"\t\t{cfg_tgt_list} /* Build configuration list for PBXNativeTarget \"WeldFatigueChecker\" */ = {{isa = XCConfigurationList; "
  f"buildConfigurations = (\n\t\t\t\t{cfg_tgt_debug} /* Debug */,\n\t\t\t\t{cfg_tgt_rel} /* Release */,\n\t\t); "
  f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
L(f"\t\t{cfg_tgt_debug} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{ {tgt_base} "
  f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; ONLY_ACTIVE_ARCH = YES; }}; name = Debug; }};")
L(f"\t\t{cfg_tgt_rel} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{ {tgt_base} "
  f"SWIFT_OPTIMIZATION_LEVEL = \"-O\"; }}; name = Release; }};")
L("/* End XCConfigurationList section */")
L("")

# ---- assemble ----
body = "\n".join(B)
pbxproj = (
    "// !$*UTF8*$!\n"
    "{\n"
    "\tarchiveVersion = 1;\n"
    "\tclasses = {\n"
    "\t};\n"
    "\tobjectVersion = 56;\n"
    "\tobjects = {\n"
    + body +
    "\t};\n"
    "\trootObject = " + project + " /* Project object */;\n"
    "}\n"
)

out_dir = os.path.join(ROOT, "WeldFatigueChecker.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, "project.pbxproj")
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(pbxproj)

# ---- 自检：括号平衡 + 所有被引用 UUID 已定义 + 无重复定义 ----
opens = pbxproj.count("{")
closes = pbxproj.count("}")
defined = set(re.findall(r"^\t\t([0-9A-F]{24}) ", pbxproj, re.M))
refs = set(re.findall(r"= ([0-9A-F]{24}) ", pbxproj))
all_def = re.findall(r"^\t\t([0-9A-F]{24}) ", pbxproj, re.M)
dups = sorted({u for u in all_def if all_def.count(u) > 1})
missing = refs - defined
print(f"swift sources: {len(swift_files)}, mm sources: {len(mm_files)}")
print(f"written: {out_path}")
print(f"braces: {{ = {opens}, }} = {closes}  -> {'OK' if opens==closes else 'MISMATCH!'}")
print(f"defined UUIDs: {len(defined)}, referenced: {len(refs)}, undefined refs: {len(missing)}, duplicate defs: {len(dups)}")
if missing:
    print("UNDEFINED:", missing)
if dups:
    print("DUPLICATE UUIDs:", dups)
if missing or dups or opens != closes:
    sys.exit(1)
print("pbxproj self-check OK")

# ---- 生成显式 .xcscheme，避免 CI 上自动 scheme 报 "buildables ... is empty" ----
scheme_dir = os.path.join(out_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme_path = os.path.join(scheme_dir, "WeldFatigueChecker.xcscheme")
scheme_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "WeldFatigueChecker.app"
               BlueprintName = "WeldFatigueChecker"
               ReferencedContainer = "container:WeldFatigueChecker.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "WeldFatigueChecker.app"
            BlueprintName = "WeldFatigueChecker"
            ReferencedContainer = "container:WeldFatigueChecker.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "WeldFatigueChecker.app"
            BlueprintName = "WeldFatigueChecker"
            ReferencedContainer = "container:WeldFatigueChecker.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
with open(scheme_path, "w", encoding="utf-8") as fh:
    fh.write(scheme_xml)
print(f"written: {scheme_path}")
