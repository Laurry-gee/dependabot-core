# frozen_string_literal: true

require "docker_registry2"

require "dependabot/update_checkers"
require "dependabot/update_checkers/base"
require "dependabot/errors"
require "dependabot/docker/tag"
require "dependabot/docker/file_parser"
require "dependabot/docker/version"
require "dependabot/docker/requirement"
require "dependabot/docker/utils/credentials_finder"

module Dependabot
  module Docker
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      def latest_version
        latest_version_from(dependency.version)
      end

      def latest_resolvable_version
        # Resolvability isn't an issue for Docker containers.
        latest_version
      end

      def latest_resolvable_version_with_no_unlock
        # No concept of "unlocking" for Docker containers
        dependency.version
      end

      def updated_requirements
        dependency.requirements.map do |req|
          updated_source = req.fetch(:source).dup

          tag = req[:source][:tag]
          digest = req[:source][:digest]

          if tag
            updated_tag = latest_version_from(tag)
            updated_source[:tag] = updated_tag
            updated_source[:digest] = digest_of(updated_tag) if digest
          elsif digest
            updated_source[:digest] = digest_of("latest")
          end

          req.merge(source: updated_source)
        end
      end

      private

      def latest_version_resolvable_with_full_unlock?
        # Full unlock checks aren't relevant for Dockerfiles
        false
      end

      def updated_dependencies_after_full_unlock
        raise NotImplementedError
      end

      def version_can_update?(*)
        if digest_requirements.any?
          !digest_up_to_date?
        else
          !version_up_to_date?
        end
      end

      def version_up_to_date?
        if digest_requirements.any?
          version_tag_up_to_date? && digest_up_to_date?
        else
          version_tag_up_to_date?
        end
      end

      def version_tag_up_to_date?
        version = dependency.version
        return false unless version

        return true unless version_tag.comparable?

        latest_tag = latest_tag_from(version)

        comparable_version_from(latest_tag) <= comparable_version_from(version_tag)
      end

      def digest_up_to_date?
        digest_requirements.all? do |req|
          next true unless updated_digest

          req.fetch(:source).fetch(:digest) == updated_digest
        end
      end

      def latest_version_from(version)
        latest_tag_from(version).name
      end

      def latest_tag_from(version)
        @tags ||= {}
        return @tags[version] if @tags.key?(version)

        @tags[version] = fetch_latest_tag(Tag.new(version))
      end

      # NOTE: It's important that this *always* returns a tag (even if
      # it's the existing one) as it is what we later check the digest of.
      def fetch_latest_tag(version_tag)
        return Tag.new(latest_digest) if version_tag.digest?
        return version_tag unless version_tag.comparable?

        # Prune out any downgrade tags before checking for pre-releases
        # (which requires a call to the registry for each tag, so can be slow)
        candidate_tags = comparable_tags_from_registry(version_tag)
        candidate_tags = remove_version_downgrades(candidate_tags, version_tag)
        candidate_tags = remove_prereleases(candidate_tags, version_tag)
        candidate_tags = filter_ignored(candidate_tags)
        candidate_tags = sort_tags(candidate_tags, version_tag)

        latest_tag = candidate_tags.last
        return version_tag unless latest_tag

        return latest_tag if latest_tag.same_precision?(version_tag)

        latest_same_precision_tag = remove_precision_changes(candidate_tags, version_tag).last
        return latest_tag unless latest_same_precision_tag

        latest_same_precision_digest = digest_of(latest_same_precision_tag.name)
        latest_digest = digest_of(latest_tag.name)

        # NOTE: Some registries don't provide digests (the API documents them as
        # optional: https://docs.docker.com/registry/spec/api/#content-digests).
        #
        # In that case we can't know for sure whether the latest tag keeping
        # existing precision is the same as the absolute latest tag.
        #
        # We can however, make a best-effort to avoid unwanted changes by
        # directly looking at version numbers and checking whether the absolute
        # latest tag is just a more precise version of the latest tag that keeps
        # existing precision.

        if latest_same_precision_digest == latest_digest && latest_same_precision_tag.same_but_less_precise?(latest_tag)
          latest_same_precision_tag
        else
          latest_tag
        end
      end

      def comparable_tags_from_registry(original_tag)
        tags_from_registry.select { |tag| tag.comparable_to?(original_tag) }
      end

      def remove_version_downgrades(candidate_tags, version_tag)
        current_version = comparable_version_from(version_tag)

        candidate_tags.select do |tag|
          comparable_version_from(tag) >= current_version
        end
      end

      def remove_prereleases(candidate_tags, version_tag)
        return candidate_tags if prerelease?(version_tag)

        candidate_tags.reject { |tag| prerelease?(tag) }
      end

      def remove_precision_changes(candidate_tags, version_tag)
        candidate_tags.select do |tag|
          tag.same_precision?(version_tag)
        end
      end

      def latest_tag
        return unless latest_digest

        tags_from_registry.
          select(&:canonical?).
          sort_by { |t| comparable_version_from(t) }.
          reverse.
          find { |t| digest_of(t.name) == latest_digest }
      end

      def updated_digest
        @updated_digest ||= if latest_tag_from(dependency.version).digest?
                              latest_digest
                            else
                              digest_of(latest_version)
                            end
      end

      def tags_from_registry
        @tags_from_registry ||=
          begin
            client = docker_registry_client

            client.tags(docker_repo_name, auto_paginate: true).fetch("tags").map { |name| Tag.new(name) }
          rescue *transient_docker_errors
            attempt ||= 1
            attempt += 1
            raise if attempt > 3

            retry
          end
      rescue DockerRegistry2::RegistryAuthenticationException,
             RestClient::Forbidden
        raise PrivateSourceAuthenticationFailure, registry_hostname
      rescue RestClient::Exceptions::OpenTimeout,
             RestClient::Exceptions::ReadTimeout
        raise if using_dockerhub?

        raise PrivateSourceTimedOut, registry_hostname
      end

      def latest_digest
        return unless tags_from_registry.map(&:name).include?("latest")

        digest_of("latest")
      end

      def digest_of(tag)
        @digests ||= {}
        return @digests[tag] if @digests.key?(tag)

        @digests[tag] = fetch_digest_of(tag)
      end

      def fetch_digest_of(tag)
        docker_registry_client.manifest_digest(docker_repo_name, tag)&.delete_prefix("sha256:")
      rescue *transient_docker_errors => e
        attempt ||= 1
        attempt += 1
        return if attempt > 3 && e.is_a?(DockerRegistry2::NotFound)
        raise if attempt > 3

        retry
      rescue DockerRegistry2::RegistryAuthenticationException,
             RestClient::Forbidden
        raise PrivateSourceAuthenticationFailure, registry_hostname
      end

      def transient_docker_errors
        [
          RestClient::Exceptions::Timeout,
          RestClient::ServerBrokeConnection,
          RestClient::ServiceUnavailable,
          RestClient::InternalServerError,
          RestClient::BadGateway,
          DockerRegistry2::NotFound
        ]
      end

      def prerelease?(tag)
        return true if tag.looks_like_prerelease?

        # Compare the numeric version against the version of the `latest` tag.
        return false unless latest_tag

        if comparable_version_from(tag) > comparable_version_from(latest_tag)
          Dependabot.logger.info "Tag with non-prerelease version name #{tag.name} detected as prerelease, " \
                                 "because it sorts higher than #{latest_tag.name}."

          true
        else
          false
        end
      end

      def comparable_version_from(tag)
        version_class.new(tag.numeric_version)
      end

      def registry_hostname
        return dependency.requirements.first[:source][:registry] if dependency.requirements.first[:source][:registry]

        credentials_finder.base_registry
      end

      def using_dockerhub?
        registry_hostname == "registry.hub.docker.com"
      end

      def registry_credentials
        credentials_finder.credentials_for_registry(registry_hostname)
      end

      def credentials_finder
        @credentials_finder ||= Utils::CredentialsFinder.new(credentials)
      end

      def docker_repo_name
        return dependency.name unless using_dockerhub?
        return dependency.name unless dependency.name.split("/").count < 2

        "library/#{dependency.name}"
      end

      def docker_registry_client
        @docker_registry_client ||=
          DockerRegistry2::Registry.new(
            "https://#{registry_hostname}",
            user: registry_credentials&.fetch("username", nil),
            password: registry_credentials&.fetch("password", nil),
            read_timeout: 10,
            http_options: { proxy: ENV.fetch("HTTPS_PROXY", nil) }
          )
      end

      def sort_tags(candidate_tags, version_tag)
        candidate_tags.sort do |tag_a, tag_b|
          if comparable_version_from(tag_a) > comparable_version_from(tag_b)
            1
          elsif comparable_version_from(tag_a) < comparable_version_from(tag_b)
            -1
          elsif tag_a.same_precision?(version_tag)
            1
          elsif tag_b.same_precision?(version_tag)
            -1
          else
            0
          end
        end
      end

      def filter_ignored(candidate_tags)
        filtered =
          candidate_tags.
          reject do |tag|
            version = comparable_version_from(tag)
            ignore_requirements.any? { |r| r.satisfied_by?(version) }
          end
        if @raise_on_ignored &&
           filter_lower_versions(filtered).empty? &&
           filter_lower_versions(candidate_tags).any? &&
           digest_requirements.none?
          raise AllVersionsIgnored
        end

        filtered
      end

      def filter_lower_versions(tags)
        tags.select do |tag|
          comparable_version_from(tag) > comparable_version_from(version_tag)
        end
      end

      def digest_requirements
        dependency.requirements.select do |requirement|
          requirement.dig(:source, :digest)
        end
      end

      def version_tag
        @version_tag ||= Tag.new(dependency.version)
      end
    end
  end
end

Dependabot::UpdateCheckers.register("docker", Dependabot::Docker::UpdateChecker)
