require 'fileutils'
require 'yaml'

module FoobarTemplates

  # This class handles the logic for finding templates
  # in the user's dir, the gem's builtin templates
  # (and on the web some day)
  class TemplateManager

    class << self

      def internal_template_location() = File.expand_path("#{File.dirname(__FILE__)}/templates")
      def custom_template_location() = File.expand_path("~/.foobar/templates")
      def default_template_name() = "ruby-cli-gem"

      # The picker uses source paths, not names, so duplicate names remain selectable.
      # Keep this separate from explicit-name resolution and its historical precedence.
      def available_templates
        entries = []
        visited = {}
        { "builtin" => internal_template_location, "custom" => custom_template_location }.each do |origin, location|
          root = File.expand_path(location)
          next unless catalog_directory?(root)

          catalog_children(root).each do |child|
            catalog_leaves(child, visited).each do |path|
              name = File.basename(path).sub(/^template-/, "")
              source = "#{origin}/#{path.delete_prefix("#{root}/")}"
              category = (load_template_config(path) || {})[:category].to_s.strip.downcase
              category = 'misc' if category.empty?
              entries << { name: name, path: path, source: source, category: category }
            end
          end
        end

        duplicates = entries.group_by { |entry| entry[:name].downcase }
        entries.sort_by { |entry| [entry[:category], entry[:name].downcase, entry[:source].downcase, entry[:source]] }.map do |entry|
          name = entry[:name]
          label = duplicates[name.downcase].length > 1 ? "#{name} (#{entry[:source]})" : name
          { name: name, label: label, path: entry[:path], category: entry[:category] }
        end
      end

      def get_template_src(options)
        template_name = options[:template] || default_template_name

        if template_exists_within_repo?(template_name)
          return resolve_template_path(internal_template_location, template_name)
        end

        custom_src = resolve_template_path(custom_template_location, template_name)
        return custom_src if File.exist?(custom_src)

        monorepo_match = resolve_monorepo_leaf_template(custom_template_location, template_name)
        return monorepo_match if monorepo_match

        raise FoobarTemplates::CLIError, "Error: template '#{template_name}' could not be found. Run the below command to list all available templates.\n\n  foobar_templates -l"
      end

      def template_exists_within_repo?(template_name)
        file_in_source?(template_name) || file_in_source?("template-#{template_name}")
      end

      def resolve_template_path(location, name)
        basic = "#{location}/#{name}"
        prefixed = "#{location}/template-#{name}"

        return basic if File.exist?(basic)
        return prefixed if File.exist?(prefixed)

        basic # fallback, even if it doesn't exist, will be caught by get_template_src
      end

      def resolve_monorepo_leaf_template(root, requested_name)
        monorepo_roots = immediate_subdirectories(root).select { |dir| monorepo_directory?(dir) }
        return nil if monorepo_roots.empty?

        requested_leaf_name = requested_name.sub(/^template-/, "")
        leaf_paths = monorepo_roots.flat_map { |dir| collect_leaf_templates(dir) }
        matches = leaf_paths.select do |leaf_path|
          File.basename(leaf_path).sub(/^template-/, "") == requested_leaf_name
        end

        if matches.length > 1
          readable_paths = matches.map { |path| path.sub(/^#{Regexp.escape(root)}\//, "") }.sort.join(", ")
          raise FoobarTemplates::CLIError, "Ambiguous template name '#{requested_name}'. Matching leaf templates: #{readable_paths}. Rename one of the conflicting templates."
        end

        if matches.empty?
          readable_leaves = leaf_paths.map { |path| File.basename(path).sub(/^template-/, "") }.uniq.sort
          raise FoobarTemplates::CLIError, "Template '#{requested_name}' not found in monorepo leaf templates. Available leaf templates: #{readable_leaves.join(', ')}. Run 'foobar_templates -l' to list all available templates."
        end

        matches.first
      end

      def collect_leaf_templates(dir)
        config = load_template_config(dir)
        return [] if config.nil?

        if config[:monorepo] == true
          immediate_subdirectories(dir).flat_map { |child| collect_leaf_templates(child) }
        else
          [dir]
        end
      end

      def monorepo_directory?(dir)
        config = load_template_config(dir)
        !config.nil? && config[:monorepo] == true
      end

      def load_template_config(dir)
        path = File.join(dir, "foobar.yml")
        return nil unless File.exist?(path)

        raw = YAML.load_file(path, symbolize_names: true)
        raw.is_a?(Hash) ? raw : {}
      rescue StandardError
        {}
      end

      def immediate_subdirectories(dir)
        return [] unless File.exist?(dir)

        Dir.children(dir).filter_map do |entry|
          full_path = File.join(dir, entry)
          File.directory?(full_path) ? full_path : nil
        end
      end

      def find_in_source_paths(target)
        path = "#{__dir__}/templates/#{target}"
        File.exist?(path) ? path : target
      end

      # Get's path to 'target' from within the gem's "templates" folder
      # within the gem's source
      def file_in_source?(target)
        src_in_source_path = "#{File.dirname(__FILE__)}/templates/#{target}"
        File.exist?(src_in_source_path)
      end

      private

      # lstat every component, including ancestors of the configured root. Do not
      # realpath first: that would hide the very symlinks we need to exclude.
      def catalog_directory?(path)
        current = File.expand_path(path)
        loop do
          stat = File.lstat(current)
          return false unless stat.directory? && !stat.symlink?
          parent = File.dirname(current)
          return true if parent == current
          current = parent
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        false
      end

      def catalog_children(path)
        Dir.children(path).sort.filter_map do |name|
          next if name.start_with?(".")
          child = File.join(path, name)
          child if catalog_directory?(child)
        end
      end

      def catalog_leaves(path, visited, nested: false)
        return [] unless catalog_directory?(path)
        stat = File.lstat(path)
        identity = [stat.dev, stat.ino]
        return [] if visited[identity]
        visited[identity] = true

        manifest = File.join(path, "foobar.yml")
        # Never read linked/special metadata, even though legacy lookup permits it.
        if File.symlink?(manifest) || (File.exist?(manifest) && !File.file?(manifest))
          return []
        end
        config = load_template_config(path)
        return [] if nested && config.nil?
        return [path] unless config && config[:monorepo] == true

        catalog_children(path).flat_map { |child| catalog_leaves(child, visited, nested: true) }
      end

    end
  end
end
