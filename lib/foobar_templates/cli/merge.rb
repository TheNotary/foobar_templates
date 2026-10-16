require 'optparse'
require 'shellwords'
require 'tmpdir'
require 'diff/lcs'
require 'diff/lcs/hunk'
require_relative 'template_picker'
require_relative '../core/conflict_buffer'

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
            tree_counts = { created: 0, overwritten: 0, unchanged: 0, skipped: 0 }
            picker = TemplatePicker.new(
              entries, input: input, output: output,
              file_lister: ->(entry) { list_files(entry) },
              file_merger: lambda do |entry, path|
                merge_file(entry, path, configurator: configurator, input: input,
                                        output: output, target: target, tally: tree_counts)
              end
            )
            begin
              picker.choose
            rescue TemplatePicker::Cancelled
              # Leaving after merging files from the tree is a normal exit.
              raise if tree_counts.values.sum.zero?
              report(output, tree_counts)
              return tree_counts
            end
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
          report(output, counts)
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

        def report(output, counts)
          output.puts "Merge complete: #{counts.fetch(:created)} created, #{counts.fetch(:overwritten)} overwritten, " \
                      "#{counts.fetch(:unchanged)} unchanged, #{counts.fetch(:skipped)} skipped."
        end

        def list_files(entry)
          require_relative '../core/template_source'
          if TemplateManager.monorepo_directory?(File.expand_path(entry.fetch(:path)))
            raise CLIError, "Select a leaf template, not monorepo container #{entry.fetch(:name).inspect}."
          end
          source = Core::TemplateSource.new(entry.fetch(:path), strict: true)
          ignored = source.ignored_relative_paths.map do |relative|
            directory = begin
              File.lstat(File.join(entry.fetch(:path), relative)).directory?
            rescue SystemCallError
              false
            end
            { path: relative, ignored: true, directory: directory }
          end
          source.files + ignored
        end

        # Runs outside the picker's raw mode: configuration prompts, the
        # overwrite prompt and the editor all use the normal terminal.
        def merge_file(entry, path, configurator:, input:, output:, target:, tally:)
          require_relative '../core/merger' unless defined?(Core::Merger)
          output.puts "Merging #{sanitize(path)} from #{sanitize(entry.fetch(:label))}"
          merger = Core::Merger.new(
            target: target, templates: [entry], selected_file: path, configurator: configurator,
            interactive_config: true, input: input, output: output
          )
          prompt = new(input: input, output: output)
          counts = merger.run(interactive: true) { |candidate, local_bytes| prompt.confirm(candidate, local_bytes) }
          counts.each { |key, value| tally[key] += value }
          status = %i[created overwritten unchanged skipped].find { |key| counts.fetch(key).positive? } || :unchanged
          output.puts "#{sanitize(path)}: #{status}"
          wait_for_return(input, output)
          status
        rescue CLIError => exception
          output.puts sanitize(exception.message, multiline: true)
          wait_for_return(input, output)
          :error
        end

        def wait_for_return(input, output)
          output.print 'Press Enter to return to the file tree.'
          output.flush
          input.gets
        end

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
            opts.separator 'Tab lists the focused template\'s files; Enter on a file merges it immediately; Tab/Esc/q go back.'
            opts.separator 'Templates merge in displayed order; files in lexical order. No default template is used.'
            opts.separator 'Only picker flows may prompt for missing configuration; -t requires configured values.'
            opts.separator 'Differing files show a colored diff (NO_COLOR disables) and require y/n approval; d re-shows it.'
            opts.separator 'e opens $VISUAL/$EDITOR (default vi) with Git-style conflict markers; save without markers to'
            opts.separator 'write the resolution. Input AND output must be TTYs.'
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

      PROMPT_CHOICES = '[y/n; choose d to show diff or e to edit]'.freeze
      DIFF_COLORS = { '-' => "\e[31m", '+' => "\e[32m", '@' => "\e[36m", '\\' => "\e[2m" }.freeze
      HEADER_COLOR = "\e[1m".freeze
      RESET = "\e[0m".freeze

      def self.color?(output)
        output.tty? && ENV['NO_COLOR'].to_s.empty? && ENV['TERM'] != 'dumb'
      end

      # editor: callable receiving an absolute buffer path; truthy on success.
      def initialize(input:, output:, multiple_templates: false, color: nil, editor: nil)
        @input, @output, @multiple_templates = input, output, multiple_templates
        @color = color.nil? ? self.class.color?(output) : color
        @editor = editor || method(:launch_editor)
      end

      # Returns true (overwrite), false (skip), or the resolved bytes to write.
      def confirm(candidate, local_bytes)
        unless @input.tty? && @output.tty?
          raise Core::Merger::ConflictError, 'Overwrite approval requires an interactive input and output terminal.'
        end
        if @multiple_templates
          @output.puts "Template: #{self.class.sanitize(candidate.template.fetch(:label))}"
        end
        texts = diffable_texts(candidate, local_bytes)
        show_diff(candidate, texts)
        pending = nil
        loop do
          @output.puts "Overwrite #{self.class.sanitize(candidate.relative_path)}? #{PROMPT_CHOICES}"
          @output.flush
          answer = @input.gets
          if answer.nil?
            raise CLIError, 'Merge cancelled (end of input). Any completed writes are retained; there is no rollback.'
          end
          case answer.strip.downcase
          when 'y' then return true
          when 'n' then return false
          when 'd' then show_diff(candidate, texts)
          when 'e'
            resolved, pending = edit(candidate, texts, pending)
            return resolved if resolved
          end
        end
      end

      private

      # [local, incoming] UTF-8 text, or nil when either side is binary/invalid.
      def diffable_texts(candidate, local_bytes)
        texts = [local_bytes, candidate.bytes].map { |bytes| bytes.dup.force_encoding(Encoding::UTF_8) }
        texts.all? { |text| text.valid_encoding? && !text.include?("\0") } ? texts : nil
      end

      def show_diff(candidate, texts)
        unless texts
          @output.puts 'Binary or invalid UTF-8 files differ; no text diff is available.'
          return
        end

        # Sanitize before diffing to preserve visible CR/control-only differences.
        # Color codes are added afterwards, so only these escapes reach the terminal.
        old_lines, new_lines = texts.map { |text| self.class.sanitize(text, multiline: true).lines }
        path = self.class.sanitize(candidate.relative_path)
        label = self.class.sanitize(candidate.template.fetch(:label))
        @output.puts paint(HEADER_COLOR, "--- local/#{path}")
        @output.puts paint(HEADER_COLOR, "+++ rendered/#{label}/#{path}")
        offset = 0
        hunks = []
        Diff::LCS.diff(old_lines, new_lines).each do |piece|
          hunk = Diff::LCS::Hunk.new(old_lines, new_lines, piece, 3, offset)
          offset = hunk.file_length_difference
          hunk.merge(hunks.pop) if hunk.overlaps?(hunks.last)
          hunks << hunk
        end
        hunks.each_with_index do |hunk, index|
          text = hunk.diff(:unified, index == hunks.length - 1)
          @output.puts text.split("\n", -1).map { |line| paint(DIFF_COLORS[line[0]], line) }.join("\n")
        end
      end

      def paint(code, line)
        @color && code && !line.empty? ? "#{code}#{line}#{RESET}" : line
      end

      # Returns [resolved_bytes_or_nil, buffer_to_resume_or_nil].
      def edit(candidate, texts, pending)
        unless texts
          @output.puts 'Binary or invalid UTF-8 files cannot be edited; choose y or n.'
          return [nil, pending]
        end

        path = self.class.sanitize(candidate.relative_path)
        label = self.class.sanitize(candidate.template.fetch(:label))
        buffer = pending || Core::ConflictBuffer.build(
          *texts, local_label: "local/#{path}", incoming_label: "rendered/#{label}/#{path}"
        )
        Dir.mktmpdir('foobar-merge-edit-') do |directory|
          # An absolute path can never be mistaken for an editor option.
          file = File.join(directory, File.basename(candidate.relative_path))
          File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |io| io.write(buffer) }
          unless @editor.call(file)
            @output.puts 'Editor did not exit successfully (check VISUAL or EDITOR); nothing was saved.'
            return [nil, pending]
          end
          edited = File.binread(file).force_encoding(Encoding::UTF_8)
          unless edited.valid_encoding?
            @output.puts 'Edited buffer is not valid UTF-8; nothing was saved.'
            return [nil, pending]
          end
          if Core::ConflictBuffer.unresolved?(edited)
            @output.puts "Conflict markers remain in #{path}; nothing was saved. Choose e to continue editing."
            return [nil, edited]
          end
          @output.puts "Saving resolved #{path}."
          [edited.b, nil]
        end
      end

      # Run the editor directly (no shell), so file names cannot inject commands.
      def launch_editor(file)
        command = [ENV['VISUAL'], ENV['EDITOR']].find { |value| !value.to_s.strip.empty? } || 'vi'
        argv = Shellwords.split(command)
        return false if argv.empty?

        system(*argv, file) ? true : false
      rescue ArgumentError => error
        @output.puts "Cannot parse editor command: #{self.class.sanitize(error.message)}"
        false
      end
    end
  end
end