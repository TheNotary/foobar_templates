require 'optparse'
require 'diff/lcs'
require 'diff/lcs/hunk'
require_relative 'template_picker'

module FoobarTemplates
  module CLI
    class Merge
      class << self
        # Command boundary: unlike legacy generation, errors produce an exit status.
        def run(argv, input: $stdin, output: $stdout, error: $stderr)
          options, parser = parse(argv)
          if options[:help]
            output.puts parser
            return 0
          end

          go(options, input: input, output: output)
          0
        rescue Interrupt
          report_error(error, 'Merge cancelled. Any completed writes are retained; there is no rollback.')
          1
        rescue StandardError, LoadError => exception
          report_error(error, exception.message)
          if defined?(Core::Merger::ConflictError) && exception.is_a?(Core::Merger::ConflictError)
            2
          else
            1
          end
        end

        def go(options = {}, input: $stdin, output: $stdout, target: Dir.pwd)
          options = validate_options(options.dup)
          # Keep help and invalid arguments independent of configuration and engine setup.
          configurator = Configurator.new
          explicit = options.key?(:template)
          templates = if explicit
            name = options.fetch(:template)
            [{ name: name, label: name, path: TemplateManager.get_template_src(template: name) }]
          else
            entries = TemplateManager.available_templates
            TemplatePicker.new(entries, input: input, output: output).choose
          end
          raise CLIError, 'No templates selected. Merge cancelled.' if templates.nil? || templates.empty?

          require_relative '../core/merger' unless defined?(Core::Merger)
          interactive = input.tty? && output.tty?
          merger = Core::Merger.new(
            target: target, templates: templates, selected_file: options[:select],
            configurator: configurator, interactive_config: !explicit && interactive,
            input: input, output: output
          )
          prompt = new(input: input, output: output, multiple_templates: templates.length > 1)
          counts = merger.run(interactive: interactive) do |candidate, local_bytes|
            prompt.confirm(candidate, local_bytes)
          end
          output.puts "Merge complete: #{counts.fetch(:created)} created, #{counts.fetch(:overwritten)} overwritten, " \
                      "#{counts.fetch(:unchanged)} unchanged, #{counts.fetch(:skipped)} skipped."
          counts
        end

        # Escape control/format characters in untrusted paths, errors and diff text.
        # Newlines are permitted only when the caller is displaying multiline text.
        def sanitize(value, multiline: false)
          text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
          text.gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) do |character|
            if multiline && character == "\n"
              character
            else
              format('\\u%04X', character.ord)
            end
          end
        end

        private

        def parse(argv)
          options = {}
          parser = OptionParser.new do |opts|
            opts.banner = 'Usage: foobar_templates merge [-t NAME] [-s PATH | -a]'
            opts.on('-t NAME', '--template NAME', 'Use one named template instead of the picker') do |value|
              raise CLIError, 'Specify -t/--template only once.' if options.key?(:template)
              options[:template] = value
            end
            opts.on('-s PATH', '--select PATH', 'Select one template-relative source file (before rendering)') do |value|
              raise CLIError, 'Specify -s/--select only once.' if options.key?(:select)
              options[:select] = value
            end
            opts.on('-a', '--merge-all-files-from-template', 'Merge all eligible files (the default; NOT force overwrite)') do
              options[:all] = true
            end
            opts.on('-h', '--help', 'Show merge help without loading configuration') { options[:help] = true }
            opts.separator ''
            opts.separator 'Target: current directory; its basename supplies the rendered project name.'
            opts.separator 'Without -t: categories flow down adaptive columns, with PARTIAL first; no horizontal scrolling.'
            opts.separator 'Up/Down (k/j) follow entries; Left/Right (h/l) move between columns.'
            opts.separator 'Space marks, Enter confirms; q/Esc cancels.'
            opts.separator 'Templates merge in displayed order; files in lexical order. No default template is used.'
            opts.separator 'Only picker flows may prompt for missing configuration; -t requires configured values.'
            opts.separator 'Differing files require y/n approval; d shows a unified diff. Input AND output must be TTYs.'
            opts.separator 'No Git init/add or bootstrap commands. Symlinks are rejected. No rollback of completed writes.'
            opts.separator 'Exit status: 0 complete (including skips), 1 error/cancel, 2 non-TTY conflict (no writes).'
          end
          remaining = parser.parse(argv.dup)
          raise CLIError, "Unexpected arguments: #{remaining.join(' ')}" unless remaining.empty?
          [validate_options(options), parser]
        end

        def validate_options(options)
          if options.key?(:select) && options[:all]
            raise CLIError, '-s/--select and -a/--merge-all-files-from-template cannot be combined.'
          end
          if options.key?(:template)
            name = options[:template]
            validate_value(name, 'Template name')
            if name.match?(%r{[/\\]}) || %w[. ..].include?(name) || name.match?(/\A[A-Za-z]:/)
              raise CLIError, 'Template name must be a name, not an absolute or traversing path.'
            end
          end
          if options.key?(:select)
            path = options[:select]
            validate_value(path, 'Selected file')
            if path.start_with?('/', '\\', '~') || path.include?('\\') ||
                path.match?(/\A[A-Za-z]:/) || path.split('/').include?('..')
              raise CLIError, 'Selected file must be a template-relative path without traversal.'
            end
            path = path.sub(%r{\A(?:\./)+}, '')
            if path.empty? || path == '.' || path.end_with?('/')
              raise CLIError, 'Select one template-relative file, not a directory.'
            end
            options[:select] = path
          end
          options
        end

        def validate_value(value, label)
          unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              !value.start_with?('-') && !value.match?(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/)
            raise CLIError, "#{label} must be a nonempty value without control characters."
          end
        end

        def report_error(error, message)
          error.puts sanitize(message, multiline: true)
        rescue IOError, SystemCallError
          # A closed diagnostic stream must not turn a handled error into a backtrace.
          nil
        end
      end

      def initialize(input:, output:, multiple_templates: false)
        @input, @output, @multiple_templates = input, output, multiple_templates
      end

      def confirm(candidate, local_bytes)
        unless @input.tty? && @output.tty?
          raise Core::Merger::ConflictError, 'Overwrite approval requires an interactive input and output terminal.'
        end
        if @multiple_templates
          @output.puts "Template: #{self.class.sanitize(candidate.template.fetch(:label))}"
        end
        loop do
          @output.puts "Overwrite #{self.class.sanitize(candidate.relative_path)}? [y/n; choose d to show diff]"
          @output.flush
          answer = @input.gets
          if answer.nil?
            raise CLIError, 'Merge cancelled (end of input). Any completed writes are retained; there is no rollback.'
          end
          case answer.strip.downcase
          when 'y' then return true
          when 'n' then return false
          when 'd' then show_diff(candidate, local_bytes)
          end
        end
      end

      private

      def show_diff(candidate, local_bytes)
        old_text = local_bytes.dup.force_encoding(Encoding::UTF_8)
        new_text = candidate.bytes.dup.force_encoding(Encoding::UTF_8)
        unless [old_text, new_text].all? { |text| text.valid_encoding? && !text.include?("\0") }
          @output.puts 'Binary or invalid UTF-8 files differ; no text diff is available.'
          return
        end

        # Sanitize before diffing to preserve visible CR/control-only differences.
        old_lines = self.class.sanitize(old_text, multiline: true).lines
        new_lines = self.class.sanitize(new_text, multiline: true).lines
        path = self.class.sanitize(candidate.relative_path)
        label = self.class.sanitize(candidate.template.fetch(:label))
        @output.puts "--- local/#{path}"
        @output.puts "+++ rendered/#{label}/#{path}"
        offset = 0
        hunks = []
        Diff::LCS.diff(old_lines, new_lines).each do |piece|
          hunk = Diff::LCS::Hunk.new(old_lines, new_lines, piece, 3, offset)
          offset = hunk.file_length_difference
          hunk.merge(hunks.pop) if hunk.overlaps?(hunks.last)
          hunks << hunk
        end
        hunks.each_with_index { |hunk, index| @output.puts hunk.diff(:unified, index == hunks.length - 1) }
      end
    end
  end
end