#!/usr/bin/env ruby

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)

def reset_project(path)
  FileUtils.rm_rf(path)
end

def configure_base_settings(target, bundle_id:, deployment_target:, info_plist: nil, product_name: nil)
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['SWIFT_VERSION'] = '6.0'
    settings['MACOSX_DEPLOYMENT_TARGET'] = deployment_target
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id if bundle_id
    settings['PRODUCT_NAME'] = product_name if product_name
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['CODE_SIGNING_ALLOWED'] = 'YES'
    settings['CODE_SIGNING_REQUIRED'] = 'YES'
    settings['DEVELOPMENT_TEAM'] = '7Q44SDV7BM'
    settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    settings['GENERATE_INFOPLIST_FILE'] = info_plist.nil? ? 'YES' : 'NO'
    settings['INFOPLIST_FILE'] = info_plist if info_plist
  end
end

def add_swift_sources(target, group, relative_paths)
  files = relative_paths.map { |path| group.new_file(path) }
  target.add_file_references(files)
end

def swift_source_names(directory)
  Dir[File.join(directory, '*.swift')].map { |path| File.basename(path) }.sort
end

def add_resources(target, group, relative_paths)
  files = relative_paths.map { |path| group.new_file(path) }
  target.add_resources(files)
end

def add_mediaremote_helper_build_phase(target)
  phase = target.new_shell_script_build_phase('Build MediaRemote Helper')
  phase.shell_path = '/bin/bash'
  phase.shell_script = <<~SH
    set -euo pipefail

    HELPER_SRC="$SRCROOT/../MediaRemoteHelper"
    HELPER_DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MediaRemoteHelper"
    HELPER_LIB="$HELPER_DEST/libkeyway_mediaremote.dylib"
    TARGET_ARCHS="${ARCHS:?ARCHS must be set}"
    ARCH_OUTPUTS=()

    mkdir -p "$HELPER_DEST"
    for ARCH in $TARGET_ARCHS; do
      ARCH_OUTPUT="$HELPER_DEST/libkeyway_mediaremote.$ARCH.dylib"
      /usr/bin/clang \\
        -dynamiclib \\
        -fobjc-arc \\
        -fblocks \\
        -arch "$ARCH" \\
        "$HELPER_SRC/KeywayMediaRemoteShim.m" \\
        -framework Foundation \\
        -o "$ARCH_OUTPUT"
      ARCH_OUTPUTS+=("$ARCH_OUTPUT")
    done

    /usr/bin/xcrun lipo -create "${ARCH_OUTPUTS[@]}" -output "$HELPER_LIB"
    rm -f "${ARCH_OUTPUTS[@]}"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPER_LIB"

    cp "$HELPER_SRC/keyway-mediaremote-helper.pl" "$HELPER_DEST/keyway-mediaremote-helper.pl"
    chmod +x "$HELPER_DEST/keyway-mediaremote-helper.pl"
  SH
  phase.input_paths = [
    '$(SRCROOT)/../MediaRemoteHelper/KeywayMediaRemoteShim.m',
    '$(SRCROOT)/../MediaRemoteHelper/keyway-mediaremote-helper.pl',
  ]
  phase.output_paths = [
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MediaRemoteHelper/libkeyway_mediaremote.dylib',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MediaRemoteHelper/keyway-mediaremote-helper.pl',
  ]
end

def add_chromium_native_host_build_phase(target)
  phase = target.new_shell_script_build_phase('Build Chromium Native Host')
  phase.shell_path = '/bin/bash'
  phase.shell_script = <<~SH
    set -euo pipefail

    PACKAGE_DIR="$SRCROOT/../packages/SonosHandoffCore"
    HELPER_DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    HELPER="$HELPER_DEST/keyway-chromium-native-host"
    SWIFT_CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
    ARCH_OUTPUTS=()

    mkdir -p "$HELPER_DEST"
    for ARCH in ${ARCHS:?ARCHS must be set}; do
      SCRATCH_PATH="$PROJECT_TEMP_DIR/keyway-chromium-native-host-$ARCH"
      swift build \\
        --package-path "$PACKAGE_DIR" \\
        --product keyway-chromium-native-host \\
        --configuration "$SWIFT_CONFIGURATION" \\
        --triple "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \\
        --sdk "$SDK_PATH" \\
        --scratch-path "$SCRATCH_PATH"
      ARCH_OUTPUT="$SCRATCH_PATH/$ARCH-apple-macosx/$SWIFT_CONFIGURATION/keyway-chromium-native-host"
      ARCH_OUTPUTS+=("$ARCH_OUTPUT")
    done

    /usr/bin/xcrun lipo -create "${ARCH_OUTPUTS[@]}" -output "$HELPER"
    chmod +x "$HELPER"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPER"
  SH
  phase.input_paths = [
    '$(SRCROOT)/../packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/HostBrowserIdentity.swift',
    '$(SRCROOT)/../packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessageRouting.swift',
    '$(SRCROOT)/../packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessageTypes.swift',
    '$(SRCROOT)/../packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessagingFraming.swift',
    '$(SRCROOT)/../packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/main.swift',
    '$(SRCROOT)/../packages/SonosHandoffCore/Package.swift',
  ]
  phase.output_paths = [
    '$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/keyway-chromium-native-host',
  ]
end

def add_chromium_extension_copy_phase(target)
  phase = target.new_shell_script_build_phase('Copy Chromium Extension')
  phase.shell_script = <<~SH
    set -euo pipefail

    EXT_SRC="$SRCROOT/../ChromiumExtension"
    EXT_DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ChromiumExtension"

    rm -rf "$EXT_DEST"
    mkdir -p "$EXT_DEST"
    cp -R "$EXT_SRC/." "$EXT_DEST/"
  SH
  phase.input_paths = [
    '$(SRCROOT)/../ChromiumExtension/manifest.json',
    '$(SRCROOT)/../ChromiumExtension/service_worker.js',
    '$(SRCROOT)/../ChromiumExtension/document_authority.js',
    '$(SRCROOT)/../ChromiumExtension/media_source_selection.js',
    '$(SRCROOT)/../ChromiumExtension/content_script.js',
    '$(SRCROOT)/../ChromiumExtension/native-host-manifest.json',
  ]
  phase.output_paths = [
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/manifest.json',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/service_worker.js',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/document_authority.js',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/media_source_selection.js',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/content_script.js',
    '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChromiumExtension/native-host-manifest.json',
  ]
end

def normalize_system_framework_refs(project, framework_name)
  project.files.each do |file|
    next unless file.display_name == framework_name

    file.path = "System/Library/Frameworks/#{framework_name}"
    file.source_tree = 'SDKROOT'
  end
end

def add_local_package_dependency(project, target, relative_path, product_name)
  package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package.relative_path = relative_path
  package.path = relative_path
  project.root_object.package_references << package

  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = product_name
  target.package_product_dependencies << product

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

def create_shared_scheme(project, scheme_name, runnable_target, test_target = nil)
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(runnable_target, test_target, launch_target: runnable_target.launchable_target_type?)
  scheme.save_as(project.path, scheme_name, true)
end

def build_menu_bar_project
  project_path = File.join(ROOT, 'SonosHandoffMenuBar', 'SonosHandoffMenuBar.xcodeproj')
  reset_project(project_path)

  project = Xcodeproj::Project.new(project_path)
  app_root = project.main_group.new_group('Keyway', 'SonosHandoffMenuBar')
  app_group = app_root.new_group('App', 'App')
  features_group = app_root.new_group('Features', 'Features')
  resources_group = app_root.new_group('Resources', 'Resources')
  support_group = app_root.new_group('Support', 'Support')

  target = project.new_target(:application, 'Keyway', :osx, '14.0', nil, :swift)
  configure_base_settings(
    target,
    bundle_id: 'com.fpieringer.Keyway',
    deployment_target: '14.0',
    info_plist: 'SonosHandoffMenuBar/Resources/Info.plist',
    product_name: 'Keyway'
  )
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    settings['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  end

  menu_bar_source_root = File.join(ROOT, 'SonosHandoffMenuBar', 'SonosHandoffMenuBar')
  add_swift_sources(target, app_group, swift_source_names(File.join(menu_bar_source_root, 'App')))
  add_swift_sources(target, features_group, swift_source_names(File.join(menu_bar_source_root, 'Features')))
  add_swift_sources(target, support_group, swift_source_names(File.join(menu_bar_source_root, 'Support')))
  add_resources(target, resources_group, [
    'Assets.xcassets',
  ])
  resources_group.new_file('Info.plist')
  add_mediaremote_helper_build_phase(target)
  add_chromium_native_host_build_phase(target)
  add_chromium_extension_copy_phase(target)

  add_local_package_dependency(project, target, '../packages/SonosHandoffCore', 'SonosHandoffCore')
  add_local_package_dependency(project, target, '../../PermissionCompanionKit', 'PermissionCompanionKit')

  normalize_system_framework_refs(project, 'Cocoa.framework')
  project.root_object.attributes['LastSwiftUpdateCheck'] = '1600'
  project.root_object.attributes['LastUpgradeCheck'] = '1600'
  Xcodeproj::Project::UUIDGenerator.new(project).generate!
  project.save
  create_shared_scheme(project, 'Keyway', target)
end

def write_workspace
  workspace_dir = File.join(ROOT, 'Keyway.xcworkspace')
  FileUtils.mkdir_p(File.join(workspace_dir, 'xcshareddata'))
  File.write(
    File.join(workspace_dir, 'contents.xcworkspacedata'),
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:SonosHandoffMenuBar/SonosHandoffMenuBar.xcodeproj"></FileRef>
      </Workspace>
    XML
  )
end

build_menu_bar_project
write_workspace
