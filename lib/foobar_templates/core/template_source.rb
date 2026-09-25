require 'open3'
require 'pathname'
require 'set'

module FoobarTemplates
  module Core
    # Template-relative discovery. Strict mode is intended for merge preflight;
    # the default retains the generator's legacy handling of source links.
    class TemplateSource
      def initialize(root, strict: false)
        @root = root.to_s
        @strict = strict
      end

      def relative_paths
        @relative_paths ||= collect_non_ignored_paths
      end

      def files
        relative_paths.select do |rel|
          rel != 'foobar.yml' && File.file?(File.join(@root, rel))
        end
      end

      def directories
        relative_paths.select { |rel| File.directory?(File.join(@root, rel)) }
      end

      # Keep Git's NUL-delimited, per-level batching: filenames can contain
      # newlines and a template can contain more paths than fit in argv.
      def ignored_paths(rel_paths)
        return Set.new if rel_paths.empty?

        stdout, _, _status = Open3.capture3(
          'git', '-C', @root, 'check-ignore', '-z', '--stdin',
          stdin_data: rel_paths.join("\x00")
        )
        stdout.split("\x00").to_set
      end

      private

      def validate_root!
        # Check before normalizing '..', so a link/../root cannot bypass the
        # ancestor check. lstat never follows the component being checked.
        absolute = Pathname.new(@root).absolute? ? @root : File.join(Dir.pwd, @root)
        current = File::SEPARATOR
        absolute.split(File::SEPARATOR).reject(&:empty?).each do |component|
          current = File.join(current, component)
          stat = File.lstat(current)
          unsupported!(current) unless stat.directory? && !stat.symlink?
        end
      end

      def unsupported!(path)
        raise FoobarTemplates::CLIError, "Unsupported template source path #{path.inspect}: symlinks and special files are not supported; source ancestors must be directories."
      end

      def collect_non_ignored_paths
        validate_root! if @strict
        results = []
        frontier = [nil]

        until frontier.empty?
          level_children = frontier.flat_map do |rel_dir|
            abs_dir = rel_dir ? File.join(@root, rel_dir) : @root
            Dir.children(abs_dir).reject { |name| name == '.git' }.map do |name|
              rel_dir ? File.join(rel_dir, name) : name
            end
          end
          break if level_children.empty?

          ignored = ignored_paths(level_children)
          frontier = []
          level_children.each do |rel|
            next if ignored.include?(rel)

            path = File.join(@root, rel)
            if @strict
              stat = File.lstat(path)
              unsupported!(path) unless stat.file? || stat.directory?
            end
            results << rel
            frontier << rel if File.directory?(path)
          end
        end
        results
      rescue SystemCallError => e
        raise unless @strict

        raise FoobarTemplates::CLIError, "Cannot read template source #{@root.inspect}: #{e.message}"
      end
    end
  end
end