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
          when 'h' then :left
          when 'j' then :down
          when 'k' then :up
          when 'l' then :right
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
        @entries = entries.sort_by do |entry|
          group = category(entry)
          [group == 'partial' ? 0 : 1, group, sanitize(entry[:name]).downcase, sanitize(entry[:label]).downcase,
           sanitize(entry[:path]).downcase, sanitize(entry[:path])]
        end
        grouped = @entries.each_index.group_by { |index| category(@entries[index]) }
        @headers = grouped.keys.map { |name| sanitize(name.upcase) }
        @groups = grouped.values
        @labels = @entries.map { |entry| sanitize(entry.fetch(:label)) }
        @label_widths = @labels.map { |label| width(label) + 5 }
        @header_widths = @headers.map { |header| width(header) }
        @terminal = terminal || Terminal.new(input, output)
      end

      # Partials first, then category/name/label/path order, never toggle order.
      def choose
        raise FoobarTemplates::CLIError, 'No templates available. Install or add templates before merging.' if @entries.empty?
        unless @terminal.tty?
          raise FoobarTemplates::CLIError, 'Template selection requires an interactive input and output terminal. Use -t TEMPLATE instead.'
        end

        @focus, @top_row, @marked = 0, 0, {}
        @layout_dimensions = nil
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
                return @marked.empty? ? [@entries[focus]] : @entries.each_index.select { |i| @marked[i] }.map { |i| @entries[i] }
              when :space
                @marked[focus] ? @marked.delete(focus) : @marked[focus] = true
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

      def category(entry)
        value = entry[:category].to_s.encode('UTF-8', invalid: :replace, undef: :replace).strip.downcase
        value.empty? ? 'misc' : value
      end

      def focus
        @focus
      end

      def sanitize(value)
        value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) do |char|
          format('\\u%04X', char.ord)
        end
      end

      def width(text)
        # v2 measures codepoints, so text symbols with emoji presentation (for
        # example sun + VS16) are undercounted. Measure those clusters as at
        # least two cells to keep neighboring columns from overlapping.
        return Unicode::DisplayWidth.of(text) unless text.include?("\uFE0F") || text.include?("\u20E3")

        text.scan(/\X/).sum do |cluster|
          cells = Unicode::DisplayWidth.of(cluster)
          cluster.match?(/[\uFE0F\u20E3]/) ? [cells, 2].max : cells
        end
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
        column, row = @positions[focus]
        case key
        when :up then @focus = [focus - 1, 0].max
        when :down then @focus = [focus + 1, @entries.length - 1].min
        when :left, :right
          neighbor = column + (key == :left ? -1 : 1)
          return unless neighbor.between?(0, @columns.length - 1)

          # Headers are not selectable; ties favor the earlier row.
          @focus = @columns[neighbor][:indices].min_by { |index| (@positions[index][1] - row).abs }
        end
      end

      # Balance only between categories. Whole blocks may exceed the balanced
      # target, but only blocks taller than twice the body height may split.
      # The last physical column keeps all remaining content for vertical scroll.
      def flow_columns(count, visible_rows)
        threshold = [3, 2 * visible_rows].max
        remaining = @entries.length + 2 * @groups.length
        group, offset = 0, 0
        Array.new(count) do |column_number|
          slots = count - column_number
          target = [(remaining + 2 * (slots - 1)) / slots, 3].max
          column = { rows: [], indices: [], width: 0 }
          last = slots == 1
          while group < @groups.length
            block_height = @groups[group].length - offset + 2
            # Move the next block whole rather than filling a balanced quota
            # with part of it. Oversized blocks start fresh at the late boundary.
            break if !last && !column[:indices].empty? &&
                     column[:rows].length + block_height > [target, threshold].min

            continued = offset.positive?
            header = @headers[group] + (continued ? ' (cont.)' : '')
            column[:rows] << { group: group, header: header }
            column[:width] = [column[:width], @header_widths[group] + (continued ? 8 : 0)].max
            remaining -= 1
            take = @groups[group].length - offset
            take = [take, threshold - 2].min unless last
            @groups[group].slice(offset, take).each do |index|
              column[:rows] << { group: group, index: index }
              column[:indices] << index
              column[:width] = [column[:width], @label_widths[index]].max
            end
            remaining -= take
            column[:rows] << { group: group, spacer: true }
            remaining -= 1
            offset += take
            if offset == @groups[group].length
              group += 1
              offset = 0
            else
              remaining += 2 # The continuation needs its own header and spacer.
              break
            end
          end
          column
        end.reject { |column| column[:indices].empty? }
      end

      # At most four linear packing passes, cached for both body dimensions.
      def reflow(available_width, visible_rows)
        dimensions = [available_width, visible_rows]
        return if @layout_dimensions == dimensions

        [4, @entries.length].min.downto(1) do |count|
          candidate = flow_columns(count, visible_rows)
          total_width = candidate.sum { |column| column[:width] } + 2 * (candidate.length - 1)
          next if total_width > available_width && count > 1

          @columns = candidate
          break
        end
        @positions = Array.new(@entries.length)
        @columns.each_with_index do |column, x|
          column[:rows].each_with_index do |cell, y|
            @positions[cell[:index]] = [x, y] if cell.key?(:index)
          end
        end
        @total_rows = @columns.map { |column| column[:rows].length }.max
        @layout_dimensions = dimensions
      end

      def cell_text(column, row, offset, visible_rows)
        cell = column[:rows][row]
        return '' unless cell && !cell[:spacer]

        if cell[:header]
          # A viewport boundary must not leave a heading without its entry.
          return offset + 1 < visible_rows ? cell[:header] : ''
        end

        following = column[:rows][row + 1]
        if offset.zero? && row.positive? && visible_rows >= 2 &&
           following && following[:group] == cell[:group] && following.key?(:index)
          return @headers[cell[:group]] # Sticky context replaces the clipped row.
        end

        index = cell[:index]
        "#{index == focus ? '>' : ' '}#{@marked[index] ? '[x]' : '[ ]'} #{@labels[index]}"
      end

      def redraw(dimensions)
        rows, terminal_columns = dimensions
        rows = [rows, 1].max
        # Leave the final terminal column unused to avoid automatic line wrapping.
        available_width = [terminal_columns - 1, 0].max
        title_rows = rows >= 3 ? 1 : 0
        footer_rows = [[rows - title_rows - 2, 0].max, 3].min
        visible_rows = rows - title_rows - footer_rows
        reflow(available_width, visible_rows)
        column, row = @positions[focus]
        @top_row = [@top_row, [@total_rows - visible_rows, 0].max].min
        context_rows = visible_rows >= 2 ? 1 : 0
        @top_row = [row - context_rows, 0].max if row < @top_row + context_rows
        @top_row = row - visible_rows + 1 if row >= @top_row + visible_rows

        lines = []
        lines << truncate('Select templates', available_width) if title_rows.positive?
        visible_rows.times do |offset|
          lines << @columns.map do |item|
            cell_width = [item[:width], available_width].min
            text = cell_text(item, @top_row + offset, offset, visible_rows)
            # Only an unavoidably over-wide single column is ever clipped.
            text = truncate(text, cell_width) if @columns.length == 1
            text + ' ' * [cell_width - width(text), 0].max
          end.join('  ').rstrip
        end
        position = "Col #{column + 1}/#{@columns.length}"
        help = '←/→ h/l columns | ↑/↓ k/j flow | Space toggle | Enter confirm | q/Esc/Ctrl-C cancel'
        footer = [
          "#{position} | #{@marked.length} selected | rows #{@top_row + 1}-#{[@top_row + visible_rows, @total_rows].min}/#{@total_rows}",
          "Focus: #{@labels[focus]}",
          help
        ]
        footer = footer.first(2) if footer_rows == 2
        footer = [footer[1]] if footer_rows == 1
        lines.concat(footer.map { |line| truncate(line, available_width) }) if footer_rows.positive?
        frame = +"\e[H\e[2J"
        lines.each_with_index { |line, index| frame << "\e[#{index + 1};1H#{line}" }
        @terminal.write(frame)
        @terminal.flush
      end
    end
  end
end