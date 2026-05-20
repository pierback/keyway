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
    settings['CODE_SIGN_IDENTITY'] = '-'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['DEVELOPMENT_TEAM'] = ''
    settings['ENABLE_HARDENED_RUNTIME'] = 'NO'
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
  app_root = project.main_group.new_group('SonosHandoffMenuBar', 'SonosHandoffMenuBar')
  app_group = app_root.new_group('App', 'App')
  features_group = app_root.new_group('Features', 'Features')
  resources_group = app_root.new_group('Resources', 'Resources')
  support_group = app_root.new_group('Support', 'Support')

  target = project.new_target(:application, 'SonosHandoffMenuBar', :osx, '14.0', nil, :swift)
  configure_base_settings(
    target,
    bundle_id: 'com.fpieringer.SonosHandoffMenuBar',
    deployment_target: '14.0',
    info_plist: 'SonosHandoffMenuBar/Resources/Info.plist'
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

  add_local_package_dependency(project, target, '../packages/SonosHandoffCore', 'SonosHandoffCore')

  create_shared_scheme(project, 'SonosHandoffMenuBar', target)
  normalize_system_framework_refs(project, 'Cocoa.framework')
  project.save
end

def write_workspace
  workspace_dir = File.join(ROOT, 'SonosHandoff.xcworkspace')
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
