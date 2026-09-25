require 'io/console'
require 'unicode/display_width'

module FoobarTemplates
  module CLI
    class TemplatePicker
      # Adapter protocol: tty?, size ([rows, columns]), raw { ... }, write,
      # flush, and read_key(timeout:) (a key symbol, nil for timeout, or :eof).
      class Terminal
        ARROWS = { 'A' => :up, 'B' => :down, 'C' => :right, 'D' => :left }.freeze

        def initialize(input, output)
          @input, @output = input, output
        end

        def tty?
          @input.tty? && @output.tty? && @input.respond_to?(:raw) &&
            @output.respond_to?(:winsize) && ENV['TERM'] != 'dumb'
        end

        def size
          rows, columns = @output.winsize
          [rows.positive? ? rows : 24, columns.positive? ? columns : 80]
        end

        def raw(&block)
          @input.raw(intr: false, &block)
        end

        def write(text)
          @output.write(text)
        end

        def flush
          @output.flush
        end

        def read_key(timeout:)
          byte = read_byte(timeout)
          case byte
          when nil, :eof then byte
          when "\e" then escape_key
          when "\r", "\n" then :enter
          when ' ' then :space
          when 'q', 'Q', "\x03" then :cancel
          when "\x04" then :eof
          else :ignore
          end
        end

        private

        def read_byte(timeout)
          # read_nonblock avoids Ruby's buffered reads disagreeing with select.
          return nil unless IO.select([@input], nil, nil, timeout)
          value = @input.read_nonblock(1, exception: false)
          return nil if value == :wait_readable
          value || :eof
        rescue EOFError
          :eof
        end

        def escape_key
          prefix = read_byte(0.05)
          return :cancel unless prefix == '[' || prefix == 'O'

          sequence = +''
          32.times do
            byte = read_byte(0.05)
            return :cancel if byte.nil? || byte == :eof
            sequence << byte
            if byte.match?(/[\x40-\x7e]/)
              return ARROWS.fetch(byte, :ignore) if sequence.match?(/\A[0-9;]*[ABCD]\z/)
              return :ignore
            end
          end
          :ignore
        end
      end

      ENTER_SCREEN = "\e[?1049h\e[?25l".freeze
      LEAVE_SCREEN = "\e[0m\e[?25h\e[?1049l".freeze

      def initialize(entries, input: $stdin, output: $stdout, terminal: nil)
        @entries = entries.dup
        @labels = entries.map { |entry| sanitize(entry.fetch(:label)) }
        @terminal = terminal || Terminal.new(input, output)
      end

      # Returns the original hashes in supplied (display) order, never toggle order.
      def choose
        raise FoobarTemplates::CLIError, 'No templates available. Install or add templates before merging.' if @entries.empty?
        unless @terminal.tty?
          raise FoobarTemplates::CLIError, 'Template selection requires an interactive input and output terminal. Use -t TEMPLATE instead.'
        end

        @focus, @top_row, @marked = 0, 0, {}
        @terminal.raw do
          begin
            @terminal.write(ENTER_SCREEN)
            dimensions = @terminal.size
            redraw(dimensions)
            loop do
              key = @terminal.read_key(timeout: 0.1)
              # Reflow before interpreting arrows if a resize occurred while waiting.
              new_dimensions = @terminal.size
              if dimensions != new_dimensions
                dimensions = new_dimensions
                redraw(dimensions)
              end
              case key
              when :cancel, :eof
                raise FoobarTemplates::CLIError, 'Template selection cancelled.'
              when :enter
                return @marked.empty? ? [@entries[@focus]] : @entries.each_index.select { |i| @marked[i] }.map { |i| @entries[i] }
              when :space
                @marked[@focus] ? @marked.delete(@focus) : @marked[@focus] = true
              when :left, :right, :up, :down
                move(key)
              else
                next
              end
              redraw(dimensions)
            end
          ensure
            @terminal.write(LEAVE_SCREEN)
            @terminal.flush
          end
        end
      rescue Interrupt
        raise FoobarTemplates::CLIError, 'Template selection cancelled.'
      rescue IOError, SystemCallError => error
        raise FoobarTemplates::CLIError, "Template selection terminal error: #{error.message}"
      end

      private

      def sanitize(value)
        value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) do |char|
          format('\\u%04X', char.ord)
        end
      end

      def width(text)
        Unicode::DisplayWidth.of(text)
      end

      def truncate(text, limit)
        return '' if limit <= 0
        return text if width(text) <= limit
        remaining = limit - 1
        result = +''
        text.scan(/\X/).each do |cluster|
          cells = width(cluster)
          break if cells > remaining
          result << cluster
          remaining -= cells
        end
        result + '…'
      end

      def move(key)
        row, column = @focus.divmod(@columns)
        candidate = case key
                    when :left then column.positive? ? @focus - 1 : @focus
                    when :right then column < @columns - 1 ? @focus + 1 : @focus
                    when :up then row.positive? ? @focus - @columns : @focus
                    when :down then @focus + @columns
                    end
        @focus = candidate if candidate < @entries.length
      end

      def redraw(dimensions)
        rows, terminal_columns = dimensions
        rows = [rows, 1].max
        # Leave the final terminal column unused to avoid automatic line wrapping.
        available_width = [terminal_columns - 1, 0].max
        header_rows = rows >= 5 ? 1 : 0
        footer_rows = [3, rows - header_rows - 1].min
        visible_rows = rows - header_rows - footer_rows
        # Cap preferred cell width so a single long name does not force one column.
        preferred_width = [[@labels.map { |label| width(label) }.max + 6, 16].max, 40].min
        @columns = [[available_width / preferred_width, 1].max, @entries.length].min
        cell_width = available_width / @columns
        focus_row = @focus / @columns
        total_rows = (@entries.length.to_f / @columns).ceil
        @top_row = [@top_row, [total_rows - visible_rows, 0].max].min
        @top_row = focus_row if focus_row < @top_row
        @top_row = focus_row - visible_rows + 1 if focus_row >= @top_row + visible_rows

        lines = []
        lines << truncate('Select templates', available_width) if header_rows.positive?
        visible_rows.times do |offset|
          row = @top_row + offset
          cells = @columns.times.map do |column|
            index = row * @columns + column
            next '' if index >= @entries.length
            marker = @marked[index] ? '[x]' : '[ ]'
            text = truncate("#{index == @focus ? '>' : ' '}#{marker} #{@labels[index]}", [cell_width - 1, 0].max)
            text + ' ' * [cell_width - width(text), 0].max
          end
          lines << cells.join
        end
        footer = [
          "#{@marked.length} selected | #{@focus + 1}/#{@entries.length} | rows #{@top_row + 1}-#{[@top_row + visible_rows, total_rows].min}/#{total_rows}",
          "Focus: #{@labels[@focus]}",
          'Arrows move | Space toggle | Enter confirm | q/Esc/Ctrl-C cancel'
        ]
        # Tiny screens prioritize the keyboard help over status/focused detail.
        lines.concat(footer.last(footer_rows).map { |line| truncate(line, available_width) }) if footer_rows.positive?
        frame = +"\e[H\e[2J"
        lines.each_with_index { |line, index| frame << "\e[#{index + 1};1H#{line}" }
        @terminal.write(frame)
        @terminal.flush
      end
    end
  end
end