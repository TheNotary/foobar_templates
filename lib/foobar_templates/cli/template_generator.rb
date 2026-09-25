require 'pathname'
require 'yaml'
require 'open3'
require 'set'
require 'fileutils'
require_relative '../core/template_source'
require_relative '../core/interpolation_context'
require_relative '../core/template_renderer'

$TRACE = false

module FoobarTemplates::CLI
  class TemplateGenerator

    attr_reader :options, :gem_name, :name, :target

    def initialize(options, gem_name)
      @options = options
      @gem_name = resolve_name(gem_name)

      @name = @gem_name
      @target = Pathname.pwd.join(gem_name)
      @template_src = ::FoobarTemplates::TemplateManager.get_template_src(options)
      @configurator = ::FoobarTemplates::Configurator.new

      @tconf = load_template_configs
    end

    def config
      @config ||= time_it("build_interpolation_config") { build_interpolation_config }
    end

    def run
      time_it("TOTAL run") do
        puts "Beginning run" if $TRACE
        raise_project_with_that_name_already_exists! if File.exist?(target)

        puts "ensure_safe_project_name" if $TRACE
        time_it("ensure_safe_project_name") do
          ensure_safe_project_name(name, config[:constant_array])
        end

        puts "run_name_validation" if $TRACE
        time_it("run_name_validation") { run_name_validation }

        template_src = time_it("match_template_src") { match_template_src }

        puts "dynamically_generate_template_directories" if $TRACE
        @template_directories = time_it("dynamically_generate_template_directories") do
          dynamically_generate_template_directories
        end

        puts "dynamically_generate_templates_files" if $TRACE
        templates = time_it("dynamically_generate_templates_files") do
          dynamically_generate_templates_files
        end

        puts "Creating new project folder '#{name}'\n\n"
        time_it("create_template_directories") do
          create_template_directories(@template_directories, target)
        end

        time_it("write_template_files") do
          templates.each do |src, dst|
            template("#{template_src}/#{src}", target.join(dst), config)
          end
        end

        time_it("git_init_and_add") do
          Dir.chdir(target) do
            if @configurator.always_perform_git_init || !inside_git_work_tree?
              `git init`
            end
            `git add .`
          end
        end

        if @tconf[:bootstrap_command]
          puts "Executing bootstrap_command"
          cmd = safe_gsub_template_variables(@tconf[:bootstrap_command])
          puts cmd
          time_it("bootstrap_command") do
            Dir.chdir(target) do
              puts `#{cmd}`
            end
          end
        end

        puts "\nComplete."
      end
    end

    def build_interpolation_config
      interpolation_context.config
    end


    private

    def interpolation_context
      @interpolation_context ||= FoobarTemplates::Core::InterpolationContext.new(
        name: name, template_root: @template_src, template_name: @options[:template],
        # Legacy generation also scans metadata for domain placeholders.
        source_files: template_relative_paths, configurator: @configurator,
        interactive: true, legacy: true, test: @options[:test]
      )
    end

    def renderer
      @renderer ||= FoobarTemplates::Core::TemplateRenderer.new(config)
    end

    def inside_git_work_tree?
      system("git rev-parse --is-inside-work-tree", out: File::NULL, err: File::NULL)
    end

    def safe_gsub_template_variables(user_string)
      renderer.render_string(user_string)
    end

    # Runs declarative name validation rules from the template's foobar.yml:
    #
    #   name_validation:
    #     reserved_names: [test, std, fmt]   # exact-match denylist
    #     regex_validator: "^[a-z][a-z0-9-]*$"  # name MUST match this pattern
    #
    # Both keys are optional. All checks run in pure Ruby — no shell, no
    # cross-platform concerns.
    def run_name_validation
      interpolation_context.run_name_validation
    end

    # Domain placeholder → config key mapping
    DOMAIN_PLACEHOLDERS = FoobarTemplates::Core::InterpolationContext::DOMAIN_PLACEHOLDERS

    # Human-readable names for prompting
    DOMAIN_DISPLAY_NAMES = FoobarTemplates::Core::InterpolationContext::DOMAIN_DISPLAY_NAMES

    DOMAIN_DEFAULTS = FoobarTemplates::Core::InterpolationContext::DOMAIN_DEFAULTS

    def scan_template_for_required_domains
      interpolation_context.scan_template_for_required_domains
    end

    def prompt_for_missing_domains(required_domains)
      interpolation_context.prompt_for_missing_domains(required_domains)
    end

    def load_template_configs
      FoobarTemplates::Core::InterpolationContext.load_template_configs(@template_src)
    end

    # Returns a hash of source directory names and their destination mappings
    def dynamically_generate_template_directories
      template_relative_paths.each_with_object({}) do |rel, dirs|
        next unless File.directory?(File.join(@template_src, rel))

        dirs[rel] = substitute_template_values(rel)
      end
    end

    # Figures out the translation between all template files and their
    # destination names
    def dynamically_generate_templates_files
      template_files = template_relative_paths.each_with_object({}) do |rel, files|
        next if rel == "foobar.yml"
        next unless File.file?(File.join(@template_src, rel))

        files[rel] = substitute_template_values(rel)
      end

      raise_no_files_in_template_error! if template_files.empty?

      return template_files
    end

    # Enumerates every relative path under the template source, skipping the
    # .git directory and any gitignored paths. Ignored directories are pruned
    # during traversal so their (potentially huge) contents are never walked.
    def template_relative_paths
      @template_relative_paths ||= time_it("collect_non_ignored_paths") do
        collect_non_ignored_paths(@template_src)
      end
    end

    # Breadth-first walk that prunes ignored directories. One batched
    # `git check-ignore` call is made per directory depth level, so we never
    # descend into (or enumerate) an ignored subtree such as node_modules.
    def collect_non_ignored_paths(root)
      FoobarTemplates::Core::TemplateSource.new(root).relative_paths
    end

    # Applies literal foo-bar variant substitutions to path strings
    def substitute_template_values(path_str)
      renderer.render_path(path_str)
    end

    def build_filename_replacement_pairs
      renderer.filename_replacement_pairs
    end

    def build_content_replacement_pairs
      renderer.content_replacement_pairs
    end

    def binary_file?(path)
      FoobarTemplates::Core::TemplateRenderer.binary_content?(File.binread(path))
    end

    # Returns the subset of the given relative paths that git considers ignored.
    # Paths are streamed via NUL-delimited stdin rather than argv to avoid the
    # OS ARG_MAX limit ("Arg list too long") and to handle paths containing
    # spaces or newlines. Returns an empty set when root is not a git repo.
    def ignored_paths(root, rel_paths)
      FoobarTemplates::Core::TemplateSource.new(root).ignored_paths(rel_paths)
    end

    def create_template_directories(template_directories, target)
      template_directories.each do |k,v|
        d = "#{target}/#{v}"
        puts " mkdir     #{d} ..."
        FileUtils.mkdir_p(d)
      end
    end

    # returns the full path of the template source
    def match_template_src
      template_src = ::FoobarTemplates::TemplateManager.get_template_src(@options)

      if File.exist?(template_src)
        return template_src    # 'newgem' refers to the built in template that comes with the gem
      else
        raise_template_not_found! # else message the user that the template could not be found
      end
    end

    def resolve_name(name)
      Pathname.pwd.join(name).basename.to_s
    end



    # Reads a template source file, performs literal string replacements
    # of foo-bar variants and FOO_ prefixed placeholders, and writes
    # the result to the destination.
    def template(source, destination, _config = {})
      source = File.expand_path(source.to_s)

      if binary_file?(source)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      else
        make_file(destination, {}) { renderer.render_file(source) }
      end

      original_mode = File.stat(source).mode
      File.chmod(original_mode, destination)
    end

    def make_file(destination, config, &block)
      FileUtils.mkdir_p(File.dirname(destination))
      puts " Writing   #{destination} ..."
      File.open(destination, "wb") { |f| f.write block.call }
    end

    def raise_no_files_in_template_error!
      raise FoobarTemplates::CLIError, <<~HEREDOC
        The template was found for '#{@options[:template]}' in ~/.foobar/templates,
        but no files were found within it.

        Exiting...
      HEREDOC
    end

    def raise_project_with_that_name_already_exists!
      raise FoobarTemplates::CLIError, <<~HEREDOC
        A project with the name #{target} already exists.
        Can't make project.  Either delete that folder or choose a new project name

        Exiting...
      HEREDOC
    end

    def raise_template_not_found!
      raise FoobarTemplates::CLIError, <<~HEREDOC
        Template not found for '#{@options[:template]}' in `~/.foobar/templates/`. 
        Please check to make sure your desired template exists.
      HEREDOC
    end

    def time_it(label = nil)
      return yield unless performance?

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_ms = ((end_time - start_time) * 1000).round(2)
      puts "#{label || 'Elapsed'}: #{elapsed_ms} ms"
      result
    end

    def performance?
      @options[:performance]
    end

    # This checks to see that the gem_name is a valid ruby gem name and will 'work'
    # and won't overlap with a foobar_templates constant apparently...
    def ensure_safe_project_name(name, constant_array)
      interpolation_context.ensure_safe_project_name(name, constant_array)
    end

  end
end
