# frozen_string_literal: true

require 'starlark_compiler/build_file'
require 'cocoapods/bazel/config'
require 'cocoapods/bazel/target'
require 'cocoapods/bazel/xcconfig_resolver'
require 'cocoapods/bazel/util'

module Pod
  module Bazel
    def self.post_install(installer:)
      return unless (config = Config.from_podfile(installer.podfile))

      default_xcconfigs = config.default_xcconfigs.transform_values do |xcconfig|
        _name, xcconfig = XCConfigResolver.resolve_xcconfig(xcconfig)
        xcconfig
      end

      UI.titled_section 'Generating Bazel files' do
        workspace = installer.config.installation_root
        sandbox = installer.sandbox
        build_files = Hash.new { |h, k| h[k] = StarlarkCompiler::BuildFile.new(workspace: workspace, package: k) }
        installer.pod_targets.each do |pod_target|
          package = sandbox.pod_dir(pod_target.pod_name).relative_path_from(workspace).to_s
          build_file = build_files[package]

          bazel_targets = [Target.new(installer, pod_target, nil, default_xcconfigs)] +
                          pod_target.file_accessors.reject { |fa| fa.spec.library_specification? }.map { |fa| Target.new(installer, pod_target, fa.spec, default_xcconfigs) }

          bazel_targets.each do |t|
            load = config.load_for(macro: t.type)
            build_file.add_load(of: load[:rule], from: load[:load])
            build_file.add_target StarlarkCompiler::AST::FunctionCall.new(load[:rule], **t.to_rule_kwargs)
          end
        end

        build_files.each_value(&:save!)
        format_files(build_files: build_files, buildifier: config.buildifier, workspace: workspace)

        cocoapods_bazel_path = File.join(sandbox.root, 'cocoapods-bazel')
        FileUtils.mkdir_p cocoapods_bazel_path

        write_cocoapods_bazel_build_file(cocoapods_bazel_path, workspace, config)
        write_non_empty_default_xcconfigs(cocoapods_bazel_path, default_xcconfigs)
      end
    end

    def self.write_cocoapods_bazel_build_file(path, workspace, config)
      FileUtils.touch(File.join(path, 'BUILD.bazel'))

      cocoapods_bazel_pkg = Pathname.new(path).relative_path_from Pathname.new(workspace)
      configs_build_file = StarlarkCompiler::BuildFile.new(workspace: workspace, package: cocoapods_bazel_pkg)

      configs_build_file.add_load(of: 'string_flag', from: '@bazel_skylib//rules:common_settings.bzl')
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('string_flag', name: 'config', build_setting_default: 'debug', visibility: ['//visibility:public'])
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'debug', flag_values: { ':config' => 'debug' })
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'release', flag_values: { ':config' => 'release' })

      configs_build_file.save!
      format_files(build_files: { cocoapods_bazel_pkg => configs_build_file }, buildifier: config.buildifier, workspace: workspace)
    end

    def self.write_non_empty_default_xcconfigs(path, default_xcconfigs)
      return if default_xcconfigs.empty?

      hash = StarlarkCompiler::AST.new(toplevel: [StarlarkCompiler::AST::Dictionary.new(default_xcconfigs)])

      File.open(File.join(path, 'default_xcconfigs.bzl'), 'w') do |f|
        f << <<~STARLARK
          """
          Default xcconfigs given as options to cocoapods-bazel.
          """

        STARLARK
        f << 'DEFAULT_XCCONFIGS = '
        StarlarkCompiler::Writer.write(ast: hash, io: f)
      end
    end

    def self.format_files(build_files:, buildifier:, workspace:)
      return if build_files.empty?

      args = []
      case buildifier
      when true
        return unless Pod::Executable.which('buildifier')

        args = ['buildifier']
      when String, Array
        args = Array(buildifier)
      else
        return
      end
      args += %w[-type build]

      executable, *args = args
      Pod::Executable.execute_command executable,
                                      args + build_files.each_key.map { |d| File.join workspace, d, 'BUILD.bazel' },
                                      true
    end
  end
end
