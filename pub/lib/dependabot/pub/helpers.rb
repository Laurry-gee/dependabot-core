# frozen_string_literal: true

require "json"
require "open3"
require "digest"

require "dependabot/errors"
require "dependabot/logger"
require "dependabot/shared_helpers"
require "dependabot/pub/requirement"

module Dependabot
  module Pub
    module Helpers
      def self.pub_helpers_path
        File.join(ENV.fetch("DEPENDABOT_NATIVE_HELPERS_PATH", nil), "pub")
      end

      def self.run_infer_sdk_versions(dir, url: nil)
        stdout, _, status = Open3.capture3(
          {},
          File.join(pub_helpers_path, "infer_sdk_versions"),
          *("--flutter-releases-url=#{url}" if url),
          chdir: dir
        )
        return nil unless status.success?

        JSON.parse(stdout)
      end

      private

      def dependency_services_list
        JSON.parse(run_dependency_services("list"))["dependencies"]
      end

      def repository_url(dependency)
        source = dependency.requirements&.first&.dig(:source)
        source&.dig("description", "url") || options[:pub_hosted_url] || "https://pub.dev"
      end

      def fetch_package_listing(dependency)
        # Because we get the security_advisories as a set of constraints, we
        # fetch the list of all versions and filter them to a list of vulnerable
        # versions.
        #
        # Ideally we would like the helper to be the only one doing requests to
        # the repository. But this should work for now:
        response = Dependabot::RegistryClient.get(url: "#{repository_url(dependency)}/api/packages/#{dependency.name}")
        JSON.parse(response.body)
      end

      def available_versions(dependency)
        fetch_package_listing(dependency)["versions"].map do |v|
          Dependabot::Pub::Version.new(v["version"])
        end
      end

      def dependency_services_smallest_update
        return @smallest_update if @smallest_update

        security_advisories.each do |a|
          # Sanity check, that we only get the advisories for a single package
          # at a time. If we got all advisories for all current dependencies,
          # the helper would be able to handle it, but we would need a better
          # way to find the repository url.
          if a.dependency_name != dependency.name
            raise "Only expected advisories for #{dependency.name} got for #{a.dependency_name}"
          end
        end
        vulnerable_versions = available_versions(dependency).select do |v|
          security_advisories.any? { |a| a.vulnerable?(v) }
        end
        input = {
          # For "smallest update" we don't cache the report to be shared between
          # dependencies, but run a specific report for the current dependency.
          target: dependency.name,
          disallowed:
            [
              {
                name: dependency.name,
                url: repository_url(dependency),
                versions: vulnerable_versions.map { |v| { range: v.to_s } }
              }
            ]
        }
        report = JSON.parse(run_dependency_services("report", stdin_data: JSON.generate(input)))["dependencies"]
        @smallest_update = report.find { |d| d["name"] == dependency.name }["smallestUpdate"]
      end

      def dependency_services_report
        sha256 = Digest::SHA256.new
        dependency_files.each do |f|
          sha256 << (f.path + "\n" + f.content + "\n")
        end
        hash = sha256.hexdigest

        cache_file = "/tmp/report-#{hash}-pid-#{Process.pid}.json"
        return JSON.parse(File.read(cache_file)) if File.file?(cache_file)

        report = JSON.parse(run_dependency_services("report", stdin_data: ""))["dependencies"]
        File.write(cache_file, JSON.generate(report))
        report
      end

      def dependency_services_apply(dependency_changes)
        run_dependency_services("apply", stdin_data: dependencies_to_json(dependency_changes)) do |temp_dir|
          dependency_files.map do |f|
            updated_file = f.dup
            updated_file.content = File.read(File.join(temp_dir, f.name))
            updated_file
          end
        end
      end

      # Clones the flutter repo into /tmp/flutter if needed
      def ensure_flutter_repo
        return if File.directory?("/tmp/flutter/.git")

        Dependabot.logger.info "Cloning the flutter repo https://github.com/flutter/flutter."
        # Make a flutter checkout
        _, stderr, status = Open3.capture3(
          {},
          "git",
          "clone",
          "--no-checkout",
          "https://github.com/flutter/flutter",
          chdir: "/tmp/"
        )
        raise Dependabot::DependabotError, "Cloning Flutter failed: #{stderr}" unless status.success?
      end

      # Will ensure that /tmp/flutter contains the flutter repo checked out at `ref`.
      def check_out_flutter_ref(ref)
        ensure_flutter_repo
        Dependabot.logger.info "Checking out Flutter version #{ref}"
        # Ensure we have the right version (by tag)
        _, stderr, status = Open3.capture3(
          {},
          "git",
          "fetch",
          "origin",
          ref,
          chdir: "/tmp/flutter"
        )
        raise Dependabot::DependabotError, "Fetching Flutter version #{ref} failed: #{stderr}" unless status.success?

        # Check out the right version in git.
        _, stderr, status = Open3.capture3(
          {},
          "git",
          "checkout",
          ref,
          chdir: "/tmp/flutter"
        )
        return if status.success?

        raise Dependabot::DependabotError, "Checking out flutter #{ref} failed: #{stderr}"
      end

      ## Detects the right flutter release to use for the pubspec.yaml.
      ## Then checks it out if it is not already.
      ## Returns the sdk versions
      def ensure_right_flutter_release(dir)
        versions = Helpers.run_infer_sdk_versions(
          File.join(dir, dependency_files.first.directory),
          url: options[:flutter_releases_url]
        )
        flutter_ref =
          if versions
            Dependabot.logger.info(
              "Installing the Flutter SDK version: #{versions['flutter']} " \
              "from channel #{versions['channel']} with Dart #{versions['dart']}"
            )
            "refs/tags/#{versions['flutter']}"
          else
            Dependabot.logger.info(
              "Failed to infer the flutter version. Attempting to use latest stable release."
            )
            # Choose the 'stable' version if the tool failed to infer a version.
            "stable"
          end

        check_out_flutter_ref flutter_ref
        run_flutter_doctor
        run_flutter_version
      end

      def run_flutter_doctor
        Dependabot.logger.info(
          "Running `flutter doctor` to install artifacts and create flutter/version."
        )
        _, stderr, status = Open3.capture3(
          {},
          "/tmp/flutter/bin/flutter",
          "doctor",
          chdir: "/tmp/flutter/"
        )
        raise Dependabot::DependabotError, "Running 'flutter doctor' failed: #{stderr}" unless status.success?
      end

      # Runs `flutter version` and returns the dart and flutter version numbers in a map.
      def run_flutter_version
        Dependabot.logger.info "Running `flutter --version`"
        # Run `flutter --version --machine` to get the current flutter version.
        stdout, stderr, status = Open3.capture3(
          {},
          "/tmp/flutter/bin/flutter",
          "--version",
          "--machine",
          chdir: "/tmp/flutter/"
        )
        unless status.success?
          raise Dependabot::DependabotError,
                "Running 'flutter --version --machine' failed: #{stderr}"
        end

        parsed = JSON.parse(stdout)
        flutter_version = parsed["frameworkVersion"]
        dart_version = parsed["dartSdkVersion"]&.split&.first
        unless flutter_version && dart_version
          raise Dependabot::DependabotError,
                "Bad output from `flutter --version`: #{stdout}"
        end
        Dependabot.logger.info(
          "Installed the Flutter SDK version: #{flutter_version} with Dart #{dart_version}."
        )
        {
          "flutter" => flutter_version,
          "dart" => dart_version
        }
      end

      def run_dependency_services(command, stdin_data: nil)
        SharedHelpers.in_a_temporary_directory do |temp_dir|
          dependency_files.each do |f|
            in_path_name = File.join(temp_dir, f.directory, f.name)
            FileUtils.mkdir_p File.dirname(in_path_name)
            File.write(in_path_name, f.content)
          end
          sdk_versions = ensure_right_flutter_release(temp_dir)
          SharedHelpers.with_git_configured(credentials: credentials) do
            env = {
              "CI" => "true",
              "PUB_ENVIRONMENT" => "dependabot",
              "FLUTTER_ROOT" => "/tmp/flutter",
              "PUB_HOSTED_URL" => options[:pub_hosted_url],
              # This variable will make the solver run assuming that Dart SDK version.
              # TODO(sigurdm): Would be nice to have a better handle for fixing the dart sdk version.
              "_PUB_TEST_SDK_VERSION" => sdk_versions["dart"]
            }
            command_dir = File.join(temp_dir, dependency_files.first.directory)

            stdout, stderr, status = Open3.capture3(
              env.compact,
              File.join(Helpers.pub_helpers_path, "dependency_services"),
              command,
              stdin_data: stdin_data,
              chdir: command_dir
            )
            raise Dependabot::DependabotError, "dependency_services failed: #{stderr}" unless status.success?
            return stdout unless block_given?

            yield command_dir
          end
        end
      end

      # Parses a dependency as listed by `dependency_services list`.
      def parse_listed_dependency(json)
        params = {
          name: json["name"],
          version: json["version"],
          package_manager: "pub",
          requirements: []
        }

        if json["kind"] != "transitive" && !json["constraint"].nil?
          constraint = json["constraint"]
          params[:requirements] << {
            requirement: constraint,
            groups: [json["kind"]],
            source: json["source"],
            file: "pubspec.yaml"
          }
        end
        Dependency.new(**params)
      end

      # Parses the updated dependencies returned by
      # `dependency_services report`.
      #
      # The `requirements_update_strategy`` is
      # used to chose the right updated constraint.
      def parse_updated_dependency(json, requirements_update_strategy: nil)
        params = {
          name: json["name"],
          version: json["version"],
          package_manager: "pub",
          requirements: []
        }
        constraint_field = constraint_field_from_update_strategy(requirements_update_strategy)

        if json["kind"] != "transitive" && !json[constraint_field].nil?
          constraint = json[constraint_field]
          params[:requirements] << {
            requirement: constraint,
            groups: [json["kind"]],
            source: nil, # TODO: Expose some information about the source
            file: "pubspec.yaml"
          }
        end

        if json["previousVersion"]
          params = {
            **params,
            previous_version: json["previousVersion"],
            previous_requirements: []
          }
          if json["kind"] != "transitive" && !json["previousConstraint"].nil?
            constraint = json["previousConstraint"]
            params[:previous_requirements] << {
              requirement: constraint,
              groups: [json["kind"]],
              source: nil, # TODO: Expose some information about the source
              file: "pubspec.yaml"
            }
          end
        end
        Dependency.new(**params)
      end

      # expects "auto" to already have been resolved to one of the other
      # strategies.
      def constraint_field_from_update_strategy(requirements_update_strategy)
        case requirements_update_strategy
        when "widen_ranges"
          "constraintWidened"
        when "bump_versions"
          "constraintBumped"
        when "bump_versions_if_necessary"
          "constraintBumpedIfNeeded"
        end
      end

      def dependencies_to_json(dependencies)
        if dependencies.nil?
          nil
        else
          deps = dependencies.map do |d|
            source = d.requirements.empty? ? nil : d.requirements.first[:source]
            obj = {
              "name" => d.name,
              "version" => d.version,
              "source" => source
            }

            obj["constraint"] = d.requirements[0][:requirement].to_s unless d.requirements.nil? || d.requirements.empty?
            obj
          end
          JSON.generate({
            "dependencyChanges" => deps
          })
        end
      end
    end
  end
end
