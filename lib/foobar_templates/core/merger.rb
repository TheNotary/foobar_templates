require 'fileutils'
require 'tmpdir'
require 'tempfile'
require_relative 'template_source'
require_relative 'interpolation_context'
require_relative 'template_renderer'

module FoobarTemplates
  module Core
    # Prepare all inputs before writing. Terminal decisions are supplied by the
    # caller; this class never initializes a terminal or runs template hooks.
    class Merger
      class ConflictError < FoobarTemplates::CLIError; end

      Candidate = Struct.new(:relative_path, :template, :staged_path, :mode, keyword_init: true) do
        def bytes
          File.binread(staged_path)
        end
      end

      def initialize(target:, templates:, selected_file: nil, configurator:,
                     interactive_config: false, input: $stdin, output: $stdout)
        @target = Pathname.new(target.to_s).absolute? ? target.to_s : File.join(Dir.pwd, target.to_s)
        @templates = templates
        @selected_file = selected_file
        @configurator = configurator
        @interactive_config = interactive_config
        @input, @output = input, output
      end

      def run(interactive: false, &resolve_conflict)
        @counts = { created: 0, overwritten: 0, unchanged: 0, skipped: 0 }
        validate_target_root!
        @target = File.expand_path(@target)
        raise CLIError, 'No templates selected.' if @templates.empty?

        Dir.mktmpdir('foobar-merge-') do |staging|
          candidates, directories = prepare(staging)
          validate_destinations!(candidates, directories)
          preflight_conflicts!(candidates) unless interactive
          directories.sort_by { |path| [path.count('/'), path] }.each do |relative|
            destination = destination_path(relative, :directory)
            FileUtils.mkdir_p(destination)
          end
          candidates.each { |candidate| apply(candidate, interactive, resolve_conflict) }
        end
        @counts
      rescue SystemCallError, IOError => e
        raise CLIError, "Merge failed: #{e.message}. Completed writes are retained; there is no rollback."
      end

      private

      def validate_target_root!
        current = File::SEPARATOR
        @target.split('/').reject(&:empty?).each do |part|
          current = File.join(current, part)
          stat = File.lstat(current)
          unless stat.directory? && !stat.symlink?
            raise CLIError, "Unsupported destination ancestor #{current.inspect}; symlinks are not supported."
          end
        end
      end

      def safe_relative!(relative)
        parts = relative.split('/')
        if relative.empty? || relative.start_with?('/') || relative.include?("\0") ||
            parts.any? { |part| part.empty? || %w[. .. .git].include?(part) }
          raise CLIError, "Unsafe relative merge path #{relative.inspect}."
        end
      end

      def prepare(staging)
        candidates, directories = [], []
        missing = []
        sources = @templates.map do |entry|
          source = TemplateSource.new(entry.fetch(:path), strict: true)
          files = source.files.sort # Validate the original, unnormalized path.
          root = File.expand_path(entry.fetch(:path))
          if root == @target || root.start_with?("#{@target}/") || @target.start_with?("#{root}/")
            raise CLIError, "Template source and destination overlap: #{root.inspect}."
          end
          if TemplateManager.monorepo_directory?(root)
            raise CLIError, "Select a leaf template, not monorepo container #{entry.fetch(:name).inspect}."
          end
          if @selected_file
            safe_relative!(@selected_file)
            missing << "#{entry.fetch(:name)}: #{@selected_file}" unless files.include?(@selected_file)
            files = files.select { |file| file == @selected_file }
          end
          [entry, root, source, files]
        end
        raise CLIError, "Selected file not found or excluded: #{missing.join(', ')}" unless missing.empty?

        sources.each do |entry, root, source, files|
          if files.empty? && source.directories.empty?
            raise CLIError, "No eligible files or directories in template #{entry.fetch(:name).inspect}."
          end
          context = InterpolationContext.new(
            name: File.basename(@target), template_root: root,
            template_name: entry.fetch(:name), source_files: files,
            configurator: @configurator, interactive: @interactive_config,
            input: @input, output: @output
          )
          context.validate!
          renderer = TemplateRenderer.new(context.config)
          seen = {}
          source_dirs = @selected_file ? [] : source.directories.sort
          (source_dirs + files).each do |relative|
            rendered = renderer.render_path(relative)
            safe_relative!(rendered)
            if seen.key?(rendered)
              raise CLIError, "Rendered path collision #{rendered.inspect}: #{seen[rendered].inspect} and #{relative.inspect}."
            end
            seen[rendered] = relative
            if source_dirs.include?(relative)
              directories << rendered
              next
            end
            path = File.join(root, relative)
            stat = File.lstat(path)
            raise CLIError, "Source changed during merge preparation: #{path.inspect}." unless stat.file?
            staged_path = File.join(staging, candidates.length.to_s)
            File.binwrite(staged_path, renderer.render_file(path))
            candidates << Candidate.new(relative_path: rendered, template: entry,
                                        staged_path: staged_path, mode: stat.mode & 0o777)
          end
        end
        [candidates, directories.uniq]
      end

      # Include implied parent directories so collisions between two templates
      # (including a file used as another file's ancestor) fail before writes.
      def validate_destinations!(candidates, directories)
        types = {}
        entries = directories.map { |path| [path, :directory] } +
                  candidates.map { |candidate| [candidate.relative_path, :file] }
        entries.each do |relative, type|
          parts = relative.split('/')
          parts.each_index do |index|
            path = parts[0..index].join('/')
            expected = index == parts.length - 1 ? type : :directory
            if types.key?(path) && types[path] != expected
              raise CLIError, "File/directory collision at #{path.inspect}."
            end
            types[path] = expected
          end
          destination_path(relative, type)
        end
      end

      # lstat every existing component, including dangling links. Never follow
      # a destination link, even if it currently resolves inside the target.
      def destination_path(relative, type = :file)
        safe_relative!(relative)
        validate_target_root!
        current = @target
        parts = relative.split('/')
        parts.each_with_index do |part, index|
          current = File.join(current, part)
          begin
            stat = File.lstat(current)
          rescue Errno::ENOENT
            next
          end
          expected = index == parts.length - 1 ? type : :directory
          valid = !stat.symlink? && (expected == :directory ? stat.directory? : stat.file?)
          raise CLIError, "Unsupported destination path or file/directory collision: #{current.inspect}." unless valid
        end
        current
      end

      def local_bytes(candidate)
        path = destination_path(candidate.relative_path)
        File.exist?(path) ? File.binread(path) : nil
      end

      def preflight_conflicts!(candidates)
        virtual = {}
        conflicts = []
        candidates.each do |candidate|
          path = candidate.relative_path
          current = virtual.key?(path) ? virtual[path] : local_bytes(candidate)
          incoming = candidate.bytes
          conflicts << path if !current.nil? && current != incoming
          virtual[path] = incoming
        end
        unless conflicts.empty?
          raise ConflictError, "Conflicting files require an interactive terminal: #{conflicts.uniq.map(&:inspect).join(', ')}. No destination files were written."
        end
      end

      def apply(candidate, interactive, resolve_conflict)
        incoming = candidate.bytes
        loop do
          current = local_bytes(candidate)
          if current == incoming
            @counts[:unchanged] += 1
            return
          end
          unless current.nil?
            unless interactive && resolve_conflict
              raise ConflictError, "File changed or conflicts require a terminal: #{candidate.relative_path.inspect}. Completed writes are retained."
            end
            unless resolve_conflict.call(candidate, current)
              @counts[:skipped] += 1
              return
            end
          end
          # A user can edit a file while viewing its diff. Reconfirm new bytes
          # rather than applying approval to a different version of the file.
          next unless local_bytes(candidate) == current

          destination = destination_path(candidate.relative_path)
          FileUtils.mkdir_p(File.dirname(destination))
          Tempfile.create(['.foobar-merge-', '.tmp'], File.dirname(destination)) do |temp|
            temp.binmode
            temp.write(incoming)
            temp.flush
            temp.chmod(candidate.mode)
            # Validate once more immediately before rename. This is per-file
            # atomic replacement, not a transaction or a filesystem lock.
            next unless local_bytes(candidate) == current
            File.rename(temp.path, destination)
            @counts[current.nil? ? :created : :overwritten] += 1
            return
          end
        end
      end
    end
  end
end