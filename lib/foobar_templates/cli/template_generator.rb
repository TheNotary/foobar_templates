require 'pathname'
require 'yaml'
require 'open3'
require 'set'

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
      title = name.tr('-', '_').split('_').map(&:capitalize).join(" ")
      pascal_name = name.tr('-', '_').split('_').map(&:capitalize).join
      unprefixed_name = name.sub(/^#{@tconf[:prefix]}/, '')
      underscored_name = name.tr('-', '_')
      constant_name = name.split('_').map{|p| p[0..0].upcase + p[1..-1] unless p.empty?}.join
      constant_name = constant_name.split('-').map{|q| q[0..0].upcase + q[1..-1] }.join('::') if constant_name =~ /-/
      constant_array = constant_name.split('::')
      git_user_name = `git config user.name`.chomp
      git_user_email = `git config user.email`.chomp

      # Resolve domain values from ~/.foobar/config, prompting if needed
      required_domains = time_it("scan_template_for_required_domains") do
        scan_template_for_required_domains
      end
      prompt_for_missing_domains(required_domains)

      registry_domain = @configurator.domain('registry_domain')
      k8s_domain = @configurator.domain('k8s_domain')
      git_repo_domain = @configurator.domain('repo_domain') || 'github.com'

      if git_user_name.empty?
        raise FoobarTemplates::CLIError, [
          "Error: git config user.name didn't return a value.  You'll probably want to make sure that's configured with your github username:",
          "",
          "git config --global user.name YOUR_GH_NAME",
        ].join("\n")
      else
        # git_repo_path = provider.com/user/name
        git_repo_path = "#{git_repo_domain}/#{git_user_name}/#{name}".downcase # downcasing for languages like go that are creative
      end

      # git_repo_url = https://provider.com/user/name
      git_repo_url = "https://#{git_repo_domain}/#{git_user_name}/#{name}"

      image_path = "#{git_user_name}/#{name}".downcase
      registry_repo_path = "#{registry_domain}/#{image_path}".downcase

      config = {
        :name             => name,
        :title            => title,
        :unprefixed_name  => unprefixed_name,
        unprefixed_pascal: unprefixed_name.tr('-', '_').split('_').map(&:capitalize).join,
        underscored_name:  underscored_name,
        :pascal_name      => pascal_name,
        :camel_name       => pascal_name.sub(/^./, &:downcase),
        :screamcase_name  => name.tr('-', '_').upcase,
        :namespaced_path  => name.tr('-', '/'),
        :makefile_path    => "#{underscored_name}/#{underscored_name}",
        :constant_name    => constant_name,
        :constant_array   => constant_array,
        :author           => git_user_name.empty? ? "TODO: Write your name" : git_user_name,
        :email            => git_user_email.empty? ? "TODO: Write your email address" : git_user_email,
        :git_repo_domain  => git_repo_domain,
        :git_repo_url     => git_repo_url,
        :git_repo_path    => git_repo_path,
        :image_path       => image_path,
        :registry_domain  => registry_domain,
        :registry_repo_path => registry_repo_path,
        :k8s_domain       => k8s_domain,
        :template         => @options[:template],
        :test             => @options[:test],
      }
    end


    private

    def inside_git_work_tree?
      system("git rev-parse --is-inside-work-tree", out: File::NULL, err: File::NULL)
    end

    def safe_gsub_template_variables(user_string)
      build_content_replacement_pairs.inject(user_string) do |result, (find, replace)|
        result.gsub(find, replace)
      end
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
      rules = @tconf[:name_validation]
      return if rules.nil? || rules.empty?

      reserved = Array(rules[:reserved_names]).map(&:to_s)
      if reserved.include?(name)
        raise FoobarTemplates::CLIError, <<~HEREDOC
          Invalid project name '#{name}': reserved by template '#{@options[:template]}'. Please choose another name.
        HEREDOC
      end

      pattern = rules[:regex_validator]
      if pattern && !pattern.to_s.empty?
        begin
          regex = Regexp.new(pattern.to_s)
        rescue RegexpError => e
          raise FoobarTemplates::CLIError, <<~HEREDOC
            Template '#{@options[:template]}' has an invalid name_validation.regex_validator: #{e.message}
          HEREDOC
        end

        unless regex.match?(name)
          raise FoobarTemplates::CLIError, <<~HEREDOC
            Invalid project name '#{name}': does not match #{regex.inspect} required by template '#{@options[:template]}'.
          HEREDOC
        end
      end
    end

    # Domain placeholder → config key mapping
    DOMAIN_PLACEHOLDERS = {
      'registry_domain' => %w[FOO_REGISTRY_DOMAIN FOO_REGISTRY_REPO_PATH],
      'k8s_domain'      => %w[FOO_K8S_DOMAIN],
      'repo_domain'     => %w[FOO_GIT_REPO_DOMAIN FOO_GIT_REPO_PATH FOO_GIT_REPO_URL],
    }.freeze

    # Human-readable names for prompting
    DOMAIN_DISPLAY_NAMES = {
      'registry_domain' => 'registry-domain',
      'k8s_domain'      => 'k8s-domain',
      'repo_domain'     => 'repo-domain',
    }.freeze

    DOMAIN_DEFAULTS = {
      'repo_domain' => 'github.com',
    }.freeze

    def scan_template_for_required_domains
      all_placeholders = DOMAIN_PLACEHOLDERS.values.flatten
      found_placeholders = Set.new

      template_relative_paths.each do |rel|
        f = File.join(@template_src, rel)
        next unless File.file?(f)
        next if binary_file?(f)

        content = File.read(f)
        all_placeholders.each do |ph|
          found_placeholders << ph if content.include?(ph)
        end
      end

      # Map found placeholders back to domain config keys
      required = Set.new
      DOMAIN_PLACEHOLDERS.each do |domain_key, placeholders|
        required << domain_key if placeholders.any? { |ph| found_placeholders.include?(ph) }
      end
      required.to_a
    end

    def prompt_for_missing_domains(required_domains)
      required_domains.each do |domain_key|
        next if @configurator.domain(domain_key) && !@configurator.domain(domain_key).empty?

        display_name = DOMAIN_DISPLAY_NAMES[domain_key]
        default = DOMAIN_DEFAULTS[domain_key]
        default_hint = default ? " (default: #{default})" : ""

        puts "This template requires '#{display_name}'. The value will be saved to ~/.foobar/config for future use."
        print "Enter #{display_name}#{default_hint}: "
        value = $stdin.gets&.chomp || ''

        value = default if value.empty? && default

        if value.empty?
          puts "Warning: No value provided for '#{display_name}'. Template placeholders may not be fully resolved."
        end

        @configurator.set_domain(domain_key, value)
      end
    end

    def load_template_configs
      template_config_path = File.join(@template_src, "foobar.yml")

      if File.exist?(template_config_path)
        t_config = YAML.load_file(template_config_path, symbolize_names: true)
      else
        t_config = {
          purpose: "tool",
          language: "go"
        }
      end

      if t_config[:prefix].nil?
        t_config[:prefix] = t_config[:purpose] ? "#{t_config[:purpose]}-" : ""
        t_config[:prefix] += t_config[:language] ? "#{t_config[:language]}-" : ""
      end

      t_config
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
      results = []
      frontier = [nil] # relative dirs to scan at the current level; nil == root

      until frontier.empty?
        level_children = []
        frontier.each do |rel_dir|
          abs_dir = rel_dir ? File.join(root, rel_dir) : root
          Dir.children(abs_dir).each do |name|
            next if name == ".git"

            level_children << (rel_dir ? File.join(rel_dir, name) : name)
          end
        end
        break if level_children.empty?

        ignored = ignored_paths(root, level_children)
        next_frontier = []
        level_children.each do |rel|
          next if ignored.include?(rel)

          results << rel
          next_frontier << rel if File.directory?(File.join(root, rel))
        end
        frontier = next_frontier
      end

      results
    end

    # Applies literal foo-bar variant substitutions to path strings
    def substitute_template_values(path_str)
      build_filename_replacement_pairs.inject(path_str) do |result, (find, replace)|
        result.gsub(find, replace)
      end
    end

    def build_filename_replacement_pairs
      [
        ['FOO_BAR',   config[:screamcase_name]],
        ['FooBar',    config[:pascal_name]],
        ['fooBar',    config[:camel_name]],
        ['foo-bar',   config[:name]],
        ['foo_bar',   config[:underscored_name]],
      ]
    end

    def build_content_replacement_pairs
      [
        # FOO_ prefixed non-name variables
        ['FOO_REGISTRY_REPO_PATH', config[:registry_repo_path] || ''],
        ['FOO_GIT_REPO_DOMAIN',    config[:git_repo_domain]],
        ['FOO_GIT_REPO_PATH',      config[:git_repo_path]],
        ['FOO_GIT_REPO_URL',       config[:git_repo_url]],
        ['FOO_REGISTRY_DOMAIN',    config[:registry_domain] || ''],
        ['FOO_IMAGE_PATH',         config[:image_path]],
        ['FOO_K8S_DOMAIN',         config[:k8s_domain] || ''],
        ['FOO_AUTHOR',             config[:author]],
        ['FOO_EMAIL',              config[:email]],
        # Name-derived: compound/longer patterns first
        ['Foo::Bar',               config[:constant_name]],
        ['FOO_BAR',                config[:screamcase_name]],
        ['FooBar',                 config[:pascal_name]],
        ['fooBar',                 config[:camel_name]],
        ['Foo Bar',                config[:title]],
        ['foo/bar',                config[:namespaced_path]],
        ['foo-bar',                config[:name]],
        ['foo_bar',                config[:underscored_name]],
      ]
    end

    def binary_file?(path)
      chunk = File.binread(path, 8192)
      chunk.nil? || chunk.include?("\x00")
    end

    # Returns the subset of the given relative paths that git considers ignored.
    # Paths are streamed via NUL-delimited stdin rather than argv to avoid the
    # OS ARG_MAX limit ("Arg list too long") and to handle paths containing
    # spaces or newlines. Returns an empty set when root is not a git repo.
    def ignored_paths(root, rel_paths)
      return Set.new if rel_paths.empty?

      stdin_data = rel_paths.join("\x00")
      stdout, _, _status = Open3.capture3(
        "git", "-C", root.to_s, "check-ignore", "-z", "--stdin",
        stdin_data: stdin_data
      )
      stdout.split("\x00").to_set
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
        content = File.read(source)
        content = content.gsub(/>>>\s+(\S+)/) { $1.chars.join("\x00") }
        build_content_replacement_pairs.each do |find, replace|
          content = content.gsub(find, replace)
        end
        content = content.gsub("\x00", '')
        make_file(destination, {}) { content }
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
      if name =~ /^\d/
        raise FoobarTemplates::CLIError, <<~HEREDOC
          Invalid gem name #{name}. Please give a name which does not start with numbers.
        HEREDOC
      end
    end

  end
end
