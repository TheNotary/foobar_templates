require 'yaml'
require 'set'
require_relative 'template_renderer'

module FoobarTemplates
  module Core
    class InterpolationContext
      DOMAIN_PLACEHOLDERS = {
        'registry_domain' => %w[FOO_REGISTRY_DOMAIN FOO_REGISTRY_REPO_PATH],
        'k8s_domain' => %w[FOO_K8S_DOMAIN],
        'repo_domain' => %w[FOO_GIT_REPO_DOMAIN FOO_GIT_REPO_PATH FOO_GIT_REPO_URL],
      }.freeze
      DOMAIN_DISPLAY_NAMES = {
        'registry_domain' => 'registry-domain',
        'k8s_domain' => 'k8s-domain',
        'repo_domain' => 'repo-domain',
      }.freeze
      DOMAIN_DEFAULTS = { 'repo_domain' => 'github.com' }.freeze

      # legacy is reserved for generator compatibility: prompt for repo_domain
      # even when a default exists and retain its warning on empty input.
      def initialize(name:, template_root:, template_name:, source_files:, configurator:,
                     interactive: false, input: $stdin, output: $stdout, legacy: false, test: nil)
        @name = name
        @template_root = template_root
        @template_name = template_name
        @source_files = source_files
        @configurator = configurator
        @interactive = interactive
        @input = input
        @output = output
        @legacy = legacy
        @test = test
        @tconf = self.class.load_template_configs(template_root)
      end

      def self.load_template_configs(root)
        path = File.join(root, 'foobar.yml')
        raw = File.exist?(path) ? YAML.load_file(path, symbolize_names: true) : { purpose: 'tool', language: 'go' }
        tconf = raw.is_a?(Hash) ? raw : {}
        if tconf[:prefix].nil?
          tconf[:prefix] = tconf[:purpose] ? "#{tconf[:purpose]}-" : ''
          tconf[:prefix] += tconf[:language] ? "#{tconf[:language]}-" : ''
        end
        tconf
      end

      def config
        @config ||= build_config
      end

      def validate!
        ensure_safe_project_name(@name)
        run_name_validation
        config
        self
      end

      def ensure_safe_project_name(name, _constant_array = nil)
        if name =~ /^\d/
          raise FoobarTemplates::CLIError, "Invalid gem name #{name}. Please give a name which does not start with numbers.\n"
        end
      end

      def run_name_validation
        rules = @tconf[:name_validation]
        return if rules.nil? || rules.empty?

        if Array(rules[:reserved_names]).map(&:to_s).include?(@name)
          raise FoobarTemplates::CLIError, "Invalid project name '#{@name}': reserved by template '#{@template_name}'. Please choose another name.\n"
        end

        pattern = rules[:regex_validator]
        return if pattern.nil? || pattern.to_s.empty?

        begin
          regex = Regexp.new(pattern.to_s)
        rescue RegexpError => e
          raise FoobarTemplates::CLIError, "Template '#{@template_name}' has an invalid name_validation.regex_validator: #{e.message}\n"
        end
        unless regex.match?(@name)
          raise FoobarTemplates::CLIError, "Invalid project name '#{@name}': does not match #{regex.inspect} required by template '#{@template_name}'.\n"
        end
      end

      def scan_template_for_required_domains
        found = Set.new
        @source_files.each do |rel|
          path = File.join(@template_root, rel)
          next unless File.file?(path)

          bytes = File.binread(path)
          next if TemplateRenderer.binary_content?(bytes)

          # Escaped tokens remain literal during rendering and need no values.
          # Preserve the historical generator scan in legacy mode.
          bytes = bytes.force_encoding(Encoding::UTF_8).gsub(/>>>\s+(\S+)/, '') unless @legacy
          DOMAIN_PLACEHOLDERS.each do |key, placeholders|
            found << key if placeholders.any? { |placeholder| bytes.include?(placeholder) }
          end
        end
        DOMAIN_PLACEHOLDERS.keys.select { |key| found.include?(key) }
      end

      def prompt_for_missing_domains(required_domains)
        missing = required_domains.reject do |key|
          present?(@configurator.domain(key)) || (!@legacy && DOMAIN_DEFAULTS.key?(key))
        end
        if !@interactive && !missing.empty?
          raise FoobarTemplates::CLIError, "Missing required template configuration: #{missing.join(', ')}. Set these values in ~/.foobar/config or use interactive template selection."
        end

        missing.each { |key| prompt_for_domain(key) }
      end

      private

      def present?(value)
        @legacy ? value && !value.empty? : !value.to_s.strip.empty?
      end

      def prompt_for_domain(key)
        display_name = DOMAIN_DISPLAY_NAMES.fetch(key)
        default = DOMAIN_DEFAULTS[key]
        hint = default ? " (default: #{default})" : ''
        @output.puts "This template requires '#{display_name}'. The value will be saved to ~/.foobar/config for future use."
        loop do
          @output.print "Enter #{display_name}#{hint}: "
          @output.flush
          answer = @input.gets
          if answer.nil? && !@legacy
            raise FoobarTemplates::CLIError, "No value provided for required '#{display_name}' (end of input)."
          end
          value = @legacy ? (answer&.chomp || '') : answer.strip
          value = default if value.empty? && default
          if value.empty?
            if @legacy
              @output.puts "Warning: No value provided for '#{display_name}'. Template placeholders may not be fully resolved."
            else
              @output.puts "A nonempty value is required for '#{display_name}'."
              next
            end
          end
          @configurator.set_domain(key, value)
          break
        end
      end

      def build_config
        name = @name
        title = name.tr('-', '_').split('_').map(&:capitalize).join(' ')
        pascal_name = name.tr('-', '_').split('_').map(&:capitalize).join
        unprefixed_name = name.sub(/^#{@tconf[:prefix]}/, '')
        underscored_name = name.tr('-', '_')
        constant_name = name.split('_').map { |p| p[0..0].upcase + p[1..-1] unless p.empty? }.join
        constant_name = constant_name.split('-').map { |q| q[0..0].upcase + q[1..-1] }.join('::') if constant_name =~ /-/
        git_user_name = `git config user.name`.chomp
        git_user_email = `git config user.email`.chomp

        prompt_for_missing_domains(scan_template_for_required_domains)
        registry_domain = @configurator.domain('registry_domain')
        k8s_domain = @configurator.domain('k8s_domain')
        git_repo_domain = @configurator.domain('repo_domain')
        git_repo_domain = 'github.com' if @legacy ? git_repo_domain.nil? : !present?(git_repo_domain)

        if git_user_name.empty?
          raise FoobarTemplates::CLIError, [
            "Error: git config user.name didn't return a value.  You'll probably want to make sure that's configured with your github username:",
            '',
            'git config --global user.name YOUR_GH_NAME',
          ].join("\n")
        end

        image_path = "#{git_user_name}/#{name}".downcase
        {
          name: name,
          title: title,
          unprefixed_name: unprefixed_name,
          unprefixed_pascal: unprefixed_name.tr('-', '_').split('_').map(&:capitalize).join,
          underscored_name: underscored_name,
          pascal_name: pascal_name,
          camel_name: pascal_name.sub(/^./, &:downcase),
          screamcase_name: name.tr('-', '_').upcase,
          namespaced_path: name.tr('-', '/'),
          makefile_path: "#{underscored_name}/#{underscored_name}",
          constant_name: constant_name,
          constant_array: constant_name.split('::'),
          author: git_user_name,
          email: git_user_email.empty? ? 'TODO: Write your email address' : git_user_email,
          git_repo_domain: git_repo_domain,
          git_repo_url: "https://#{git_repo_domain}/#{git_user_name}/#{name}",
          git_repo_path: "#{git_repo_domain}/#{git_user_name}/#{name}".downcase,
          image_path: image_path,
          registry_domain: registry_domain,
          registry_repo_path: "#{registry_domain}/#{image_path}".downcase,
          k8s_domain: k8s_domain,
          template: @template_name,
          test: @test,
        }
      end
    end
  end
end