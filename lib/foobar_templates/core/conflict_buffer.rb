require 'diff/lcs'

module FoobarTemplates
  module Core
    # Two-way, Git-style conflict text. Unchanged lines are emitted verbatim;
    # each changed region is wrapped in <<<<<<< / ======= / >>>>>>> markers.
    module ConflictBuffer
      MARKER = /^(?:<{7}(?: |\r?$)|={7}\r?$|>{7}(?: |\r?$))/.freeze

      module_function

      def build(local, incoming, local_label:, incoming_label:)
        buffer = +''
        ours, theirs = [], []
        flush = lambda do
          next if ours.empty? && theirs.empty?

          buffer << "<<<<<<< #{local_label}\n"
          ours.each { |line| buffer << line }
          buffer << "=======\n"
          theirs.each { |line| buffer << line }
          buffer << ">>>>>>> #{incoming_label}\n"
          ours.clear
          theirs.clear
        end
        Diff::LCS.sdiff(local.lines, incoming.lines).each do |change|
          case change.action
          when '='
            flush.call
            buffer << change.old_element
          when '-' then ours << terminated(change.old_element)
          when '+' then theirs << terminated(change.new_element)
          when '!'
            ours << terminated(change.old_element)
            theirs << terminated(change.new_element)
          end
        end
        flush.call
        buffer
      end

      def unresolved?(text)
        MARKER.match?(text)
      end

      # A marker must begin its own line, even after a final unterminated line.
      def terminated(line)
        line.end_with?("\n") ? line : "#{line}\n"
      end
    end
  end
end
