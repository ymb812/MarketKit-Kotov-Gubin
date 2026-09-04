# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module IntegrationGenerator
  module Generator
    class OutputWriter
      def write(artifacts, output_path)
        target = File.expand_path(output_path)
        parent = File.dirname(target)
        FileUtils.mkdir_p(parent)
        lock_path = File.join(parent, ".#{safe_basename(target)}.lock")
        lock = File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL)

        begin
          raise Error.new("OUTPUT_EXISTS", "Refusing to overwrite existing output", location: target) if File.exist?(target)

          staging = Dir.mktmpdir(".#{safe_basename(target)}.staging-", parent)
          begin
            artifacts.each do |name, content|
              validate_filename!(name)
              File.binwrite(File.join(staging, name), content.encode("UTF-8"))
            end
            validate_written_artifacts!(artifacts, staging)
            raise Error.new("OUTPUT_EXISTS", "Refusing to overwrite existing output", location: target) if File.exist?(target)

            File.rename(staging, target)
            staging = nil
          ensure
            FileUtils.remove_entry(staging) if staging && File.exist?(staging)
          end
        ensure
          lock.close
          File.delete(lock_path) if File.file?(lock_path)
        end

        target
      rescue Errno::EEXIST => e
        raise Error.new("OUTPUT_EXISTS", "Output exists or generation is already in progress: #{e.message}", location: output_path)
      rescue SystemCallError => e
        raise Error.new("OUTPUT_WRITE_FAILED", e.message, location: output_path)
      end

      private

      def safe_basename(path)
        File.basename(path).gsub(/[^a-zA-Z0-9_.-]+/, "_")
      end

      def validate_filename!(name)
        reserved = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i
        safe = name.is_a?(String) &&
               name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/) &&
               !name.match?(reserved)
        return if safe

        raise Error.new("GENERATION_INVALID", "Artifact filename is unsafe: #{name.inspect}")
      end

      def validate_written_artifacts!(artifacts, staging)
        service_name = artifacts.keys.find { |name| name.end_with?("_service.rb") }
        return unless service_name

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", File.join(staging, service_name))
        return if status.success?

        detail = [stdout, stderr].reject(&:empty?).join(" ").strip
        raise Error.new("GENERATION_INVALID", "Generated Ruby failed ruby -c: #{detail}")
      end
    end
  end
end
