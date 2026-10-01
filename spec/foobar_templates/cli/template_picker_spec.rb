require 'spec_helper'
require 'foobar_templates/cli/template_picker'
require 'stringio'
require 'pty'
require 'timeout'

RSpec.describe FoobarTemplates::CLI::TemplatePicker do
  class PickerTestTerminal
    attr_reader :writes, :frames, :restored
    attr_accessor :dimensions, :events, :interactive, :raw_active

    def initialize(events, dimensions)
      @events, @dimensions = events, dimensions
      @writes, @frames = [], []
      @interactive = true
    end

    def tty? = @interactive
    def size = @dimensions.dup
    def flush; end

    def write(text)
      @writes << text
      @frames << text if text.start_with?("\e[H\e[2J")
    end

    def raw
      @raw_active = true
      yield
    ensure
      @raw_active = false
      @restored = true
    end

    def read_key(timeout:)
      event = @events.shift || :eof
      return event.call(self) if event.respond_to?(:call)
      raise event if event.is_a?(Exception)
      event
    end
  end

  def entries(count = 10)
    Array.new(count) { |i| { name: "item#{i}", label: "item#{i}", path: "/templates/#{i}" } }
  end

  def choose(events, dimensions: [10, 49], items: entries)
    @terminal = PickerTestTerminal.new(events, dimensions)
    @picker = described_class.new(items, terminal: @terminal)
    @picker.choose
  end

  def frame_lines(frame)
    frame.sub("\e[H\e[2J", '').split(/\e\[\d+;1H/).drop(1)
  end

  def categorized_entries
    entries(6).each_with_index.map do |entry, index|
      entry.merge(category: %w[partial partial partial backend frontend frontend][index])
    end
  end

  def flowing_entries(groups = 8, size = 2)
    Array.new(groups) do |group|
      category = (97 + group).chr
      Array.new(size) do |index|
        label = "#{category}#{index.to_s.rjust(2, '0')}"
        { category: category, name: label, label: label, path: "/#{label}" }
      end
    end.flatten
  end

  def columns
    @picker.instance_variable_get(:@columns)
  end

  def expect_category_blocks
    columns.each do |column|
      expect(column[:indices]).not_to be_empty
      expect(column[:rows].filter_map { |cell| cell[:index] }).to eq(column[:indices])
      column[:rows].slice_before { |cell| cell.key?(:header) }.each do |block|
        expect(block.first).to have_key(:header)
        expect(block.length).to be >= 3
        expect(block[1...-1]).to all(have_key(:index))
        expect(block.last).to eq(group: block.first[:group], spacer: true)
        expect(block.map { |cell| cell[:group] }.uniq).to eq([block.first[:group]])
      end
    end
    @picker.instance_variable_get(:@positions).each_with_index do |(column, row), index|
      expect(columns[column][:rows][row]).to include(index: index)
    end
  end

  def expect_bounded_frames(dimensions)
    @terminal.frames.each do |frame|
      lines = frame_lines(frame)
      expect(lines.length).to be <= dimensions[0]
      expect(lines.all? { |line| Unicode::DisplayWidth.of(line) < dimensions[1] }).to be(true)
    end
  end

  it 'confirms focus if nothing is marked and returns original entry hashes' do
    items = entries
    expect(choose([:down, :enter], items: items).first).to equal(items[1])
  end

  it 'toggles in place, confirms only marked entries, and returns display rather than toggle order' do
    items = entries
    result = choose([:down, :space, :up, :space, :right, :enter], items: items)
    expect(result).to eq([items[0], items[1]])
    expect(@terminal.frames[2]).to include('>[x] item1')
    expect(@terminal.frames.last).to include('2 selected')
  end

  it 'unmarks without moving focus and falls back to focus when every mark is removed' do
    expect(choose([:down, :space, :space, :enter])).to eq([entries[1]])
  end

  it 'stacks category blocks in four balanced columns rather than one column per category' do
    choose([:enter], items: flowing_entries, dimensions: [12, 81])
    lines = frame_lines(@terminal.frames.first)
    expect(lines[0]).to eq('Select templates')
    expect(lines[1].split).to eq(%w[A C E G])
    expect(lines[4]).to eq('')
    expect(lines[5].split).to eq(%w[B D F H])
    expect(lines[8]).to eq('')
    expect(columns.map { |column| column[:rows].length }).to eq([8, 8, 8, 8])
    expect(columns.flat_map { |column| column[:indices] }).to eq((0...16).to_a)
    expect_category_blocks
    expect(lines[-3]).to include('Col 1/4')
    expect(lines.last).to include('←/→ h/l columns', '↑/↓ k/j flow')
    expect_bounded_frames([12, 81])
  end

  it 'uses measured widths to fall back from four to three, two and one columns without clipping labels' do
    # Each four-column cell is eight display cells wide, with two-cell gaps.
    { 39 => 4, 38 => 3, 25 => 2, 18 => 1 }.each do |terminal_width, count|
      choose([:enter], items: flowing_entries, dimensions: [40, terminal_width])
      expect(columns.length).to eq(count)
      expect(frame_lines(@terminal.frames.first)[1...-3].join).not_to include('…')
      expect_bounded_frames([40, terminal_width])
    end
  end

  it 'lets a long entry widen only its own column and displace the next column' do
    items = flowing_entries
    choose([:enter], items: items, dimensions: [14, 81])
    before = frame_lines(@terminal.frames.first)[1].index('C')
    items[0][:label] = 'a' * 25
    choose([:enter], items: items, dimensions: [14, 81])
    expect(columns.map { |column| column[:width] }).to eq([30, 8, 8, 8])
    expect(frame_lines(@terminal.frames.first)[1].index('C')).to eq(before + 22)
    expect(@terminal.frames.first).to include('>[ ] ' + 'a' * 25)
    expect_bounded_frames([14, 81])
    choose([:enter], items: items, dimensions: [14, 61])
    expect(columns.length).to eq(4)
    choose([:enter], items: items, dimensions: [14, 60])
    expect(columns.length).to eq(3)
    expect(frame_lines(@terminal.frames.first)[1...-3].join).not_to include('…')
  end

  it 'measures headers as well as labels and gives every column its natural width' do
    items = flowing_entries(4)
    items.last[:category] = 'very long category'
    choose([:enter], items: items, dimensions: [18, 100])
    columns.each do |column|
      expected = column[:rows].map do |cell|
        next 0 if cell[:spacer]
        cell[:header] ? Unicode::DisplayWidth.of(cell[:header]) : Unicode::DisplayWidth.of(items[cell[:index]][:label]) + 5
      end.max
      expect(column[:width]).to eq(expected)
    end
    expect(@terminal.frames.first).to include('VERY LONG CATEGORY')
    expect_bounded_frames([18, 100])
  end

  it 'allocates two cells to emoji-presentation symbols without wrapping adjacent columns' do
    items = flowing_entries(4)
    items.each { |item| item[:label] = "☀️" * 12 }
    [80, 120].each do |terminal_width|
      choose([:enter], items: items, dimensions: [20, terminal_width])
      expect(columns.length).to be < 4
      @terminal.frames.each do |frame|
        frame_lines(frame).each do |line|
          # Independent cell count: replace emoji with a known two-cell CJK glyph.
          expect(Unicode::DisplayWidth.of(line.gsub("☀️", '界'))).to be < terminal_width
        end
      end
    end
    choose([:enter], items: items, dimensions: [8, 18])
    expect(frame_lines(@terminal.frames.first).all? do |line|
      Unicode::DisplayWidth.of(line.gsub("☀️", '界')) < 18
    end).to be(true)
  end

  it 'splits oversized categories at the late boundary rather than the balanced quota' do
    choose([:enter], items: entries(32), dimensions: [20, 160])
    # Sixteen body rows: thirty entries plus header and spacer before wrapping.
    expect(columns.map { |column| column[:rows].first[:header] }).to eq(['MISC', 'MISC (cont.)'])
    expect(columns.map { |column| column[:rows].length }).to eq([32, 4])
    expect_category_blocks
    [1, 2, 3, 7, 20].each do |count|
      choose([:enter], items: entries(count), dimensions: [20, 160])
      expect(columns.length).to be <= [count, 4].min
      expect_category_blocks
    end
  end

  { 9 => [11], 10 => [12], 11 => [12, 3] }.each do |size, heights|
    it "keeps a #{size + 2}-row block intact unless it exceeds twice the six-row body" do
      choose([:enter], items: flowing_entries(1, size), dimensions: [10, 81])
      expect(columns.map { |column| column[:rows].length }).to eq(heights)
      expect(columns.map { |column| column[:rows].first[:header] }).to eq(
        heights.length == 1 ? ['A'] : ['A', 'A (cont.)']
      )
      expect(columns.flat_map { |column| column[:indices] }).to eq((0...size).to_a)
      expect_category_blocks
      expect_bounded_frames([10, 81])
    end
  end

  it 'preserves a long category above the balanced target, including when moved to the next column' do
    %w[a b].each do |long_category|
      items = flowing_entries(4, 10).select { |item| item[:category] == long_category || item[:name].end_with?('00', '01') }
      choose([:enter], items: items, dimensions: [10, 81])
      expect(columns.map { |column| column[:rows].first[:header] }).to eq(%w[A B C D])
      expect(columns.map { |column| column[:indices].length }).to eq(long_category == 'a' ? [10, 2, 2, 2] : [2, 10, 2, 2])
      expect_category_blocks
    end
  end

  it 'moves an oversized category to a fresh column before splitting at the late boundary' do
    items = flowing_entries(4, 11).select { |item| item[:category] == 'b' || item[:name].end_with?('00', '01') }
    choose([:enter], items: items, dimensions: [10, 81])
    expect(columns.map { |column| column[:rows].first[:header] }).to eq(['A', 'B', 'B (cont.)', 'C'])
    expect(columns[0][:indices].length).to eq(2)
    expect(columns[1][:rows].length).to eq(12)
    expect(columns.flat_map { |column| column[:indices] }).to eq((0...items.length).to_a)
    expect_category_blocks
  end

  it 'keeps the remainder reachable in the last physical column at every adaptive width' do
    items = flowing_entries(1, 50)
    # A is eight cells wide; each continuation heading is nine cells wide.
    { 42 => 4, 41 => 3, 30 => 2, 19 => 1 }.each do |terminal_width, count|
      result = choose([:space] + [:down, :space] * 49 + [:enter], items: items, dimensions: [10, terminal_width])
      expect(columns.length).to eq(count)
      expect(columns[0...-1].map { |column| column[:rows].length }).to eq([12] * (count - 1))
      expect(columns.last[:rows].length).to eq(52 - 10 * (count - 1))
      expect(result.map(&:object_id)).to eq(items.map(&:object_id))
      expect_category_blocks
      expect_bounded_frames([10, terminal_width])
      expect(frame_lines(@terminal.frames.last)[1...-3].join).to include('>[x] a49')
    end
  end

  it 'uses a minimum three-row block even with only one visible body row' do
    choose([:down] * 9 + [:enter], items: flowing_entries(1, 10), dimensions: [1, 81])
    expect(columns.map { |column| column[:rows].length }).to eq([3, 3, 3, 9])
    expect_category_blocks
    expect(@terminal.frames.last).to include('>[ ] a09')
    expect_bounded_frames([1, 81])
  end

  it 'moves down and up through stacked category boundaries and flows between columns' do
    items = flowing_entries
    expect(choose([:down, :down, :enter], items: items, dimensions: [12, 81])).to eq([items[2]])
    expect(@terminal.frames.last).to include('>[ ] b00')
    expect(choose([:down] * 4 + [:enter], items: items, dimensions: [12, 81])).to eq([items[4]])
    expect(choose([:down] * 4 + [:up, :enter], items: items, dimensions: [12, 81])).to eq([items[3]])
    expect(choose([:up, :left, :enter], items: items)).to eq([items[0]])
    expect(choose([:down] * 20 + [:right, :enter], items: items)).to eq([items.last])
  end

  it 'moves horizontally to the nearest selectable row, not the next category' do
    items = flowing_entries
    expect(choose([:down, :right, :enter], items: items, dimensions: [12, 81])).to eq([items[5]])
    expect(choose([:down, :right, :left, :enter], items: items, dimensions: [12, 81])).to eq([items[1]])
    choose([:enter], items: items, dimensions: [16, 38])
    positions = @picker.instance_variable_get(:@positions)
    source = columns.first[:indices].last
    expected = columns[1][:indices].min_by { |index| (positions[index][1] - positions[source][1]).abs }
    expect(choose([:down] * source + [:right, :enter], items: items, dimensions: [16, 38])).to eq([items[expected]])
  end

  it 'normalizes case and blank categories, prioritizes PARTIAL and keeps original identity' do
    items = entries(7)
    [nil, '', '  ', ' Partial ', 'PARTIAL', 'partial', 'Backend'].each_with_index do |category, index|
      items[index][:category] = category
    end
    items[0].delete(:category)
    original = Marshal.load(Marshal.dump(items))
    items.each(&:freeze)
    result = choose(([:space, :down] * items.length) + [:enter], items: items, dimensions: [20, 18])
    expect(result.map(&:object_id)).to eq([3, 4, 5, 6, 0, 1, 2].map { |i| items[i].object_id })
    expect(columns.first[:rows].filter_map { |cell| cell[:header] }).to eq(%w[PARTIAL BACKEND MISC])
    expect(items).to eq(original)
    items[0] = original[0].merge(category: nil)
    choose([:enter], items: items, dimensions: [20, 18])
    expect(columns.first[:rows].filter_map { |cell| cell[:header] }).to eq(%w[PARTIAL BACKEND MISC])
  end

  it 'skips spacers on horizontal moves instead of selecting the blank row' do
    items = flowing_entries
    items.delete_at(7) # D's trailing spacer is opposite B's last entry.
    result = choose([:down] * 3 + [:right, :enter], items: items, dimensions: [12, 81])
    expect(columns[1][:rows][6]).to eq(group: 3, spacer: true)
    expect(result.first).to equal(items[6])
    expect(result.first[:label]).to eq('d00')
    expect(@terminal.frames.last).to include('>[ ] d00')
  end

  it 'skips headers on horizontal moves and chooses the closest entry across category spacers' do
    items = flowing_entries
    items.insert(2, { category: 'a', name: 'a02', label: 'a02', path: '/a02' })
    items.delete_at(8)
    # B's last entry faces E's header; d00 is two rows away, e00 only one.
    result = choose([:down] * 4 + [:right, :enter], items: items, dimensions: [16, 38])
    expect(columns[1][:rows][7][:header]).to eq('E')
    expect(result.first).to equal(items[8])
    expect(@terminal.frames.last).to include('>[ ] e00')
  end

  it 'keeps all column origins visible and fixed when moving horizontally' do
    choose([:right] * 3 + [:left] * 3 + [:enter], items: flowing_entries, dimensions: [12, 81])
    expect(@terminal.frames.map { |frame| frame_lines(frame)[1] }.uniq).to eq(['A         C         E         G'])
    expect_bounded_frames([12, 81])
  end

  it 'sorts by category, name, label and path and returns marked originals in sorted, not toggle order' do
    items = [
      { category: 'Z', name: 'a', label: 'a', path: '/z' },
      { category: 'a', name: 'b', label: 'b', path: '/b' },
      { category: ' A ', name: 'a', label: 'z', path: '/z' },
      { category: 'a', name: 'a', label: 'a', path: '/2' },
      { category: 'A', name: 'a', label: 'a', path: '/1' }
    ]
    result = choose([:down] * 4 + [:space, :up] * 4 + [:space, :enter], items: items)
    expect(result.map(&:object_id)).to eq(items.reverse.map(&:object_id))
  end

  it 'scrolls only vertically, repeats active category context, and returns to the top' do
    items = flowing_entries(8, 8)
    choose([:down] * 7 + [:enter], items: items, dimensions: [9, 81])
    lines = frame_lines(@terminal.frames.last)
    expect(columns.length).to eq(4)
    expect(lines[1].split).to eq(%w[A B C D])
    expect(lines[5]).to include('>[ ] a07', 'b07', 'c07', 'd07')
    expect(lines[-3]).to include('rows 5-9/')
    expect_bounded_frames([9, 81])
    choose([:down] * 7 + [:up] * 7 + [:enter], items: items, dimensions: [9, 81])
    expect(@terminal.frames.last).to include('>[ ] a00', 'rows 1-5/')
  end

  it 'renders exactly one blank row after each category in a single column' do
    choose([:enter], items: flowing_entries(3), dimensions: [16, 18])
    expect(columns.length).to eq(1)
    body = frame_lines(@terminal.frames.first)[1...-3]
    expect(body).to eq([
      'A', '>[ ] a00', ' [ ] a01', '',
      'B', ' [ ] b00', ' [ ] b01', '',
      'C', ' [ ] c00', ' [ ] c01', ''
    ])
    expect_category_blocks
    expect_bounded_frames([16, 18])
  end

  it 'renders a blank row after every continuation block, not an extra global footer spacer' do
    choose([:down] * 7 + [:enter], items: flowing_entries(1, 32), dimensions: [9, 81])
    expect(columns.length).to eq(4)
    expect(columns.map { |column| column[:rows].first[:header] }).to eq(['A'] + ['A (cont.)'] * 3)
    expect(columns.map { |column| column[:rows].length }).to eq([10, 10, 10, 10])
    # Scroll one row farther to inspect the planned trailing spacers together.
    @picker.instance_variable_set(:@top_row, 5)
    @picker.send(:redraw, [9, 81])
    lines = frame_lines(@terminal.frames.last)
    expect(lines[4]).to include('a07', 'a15', 'a23', 'a31')
    expect(lines[5]).to eq('')
    expect(lines[6]).to start_with('Col ')
    expect_category_blocks
    expect_bounded_frames([9, 81])
  end

  it 'keeps focus and marks on entries when navigating category spacers and resizing' do
    shrink = ->(terminal) { terminal.dimensions = [6, 18]; nil }
    grow = ->(terminal) { terminal.dimensions = [12, 81]; nil }
    shorter = ->(terminal) { terminal.dimensions = [7, 81]; nil }
    verify_focus = lambda do |_terminal|
      expect(@terminal.frames.last).to include('>[x] c00')
      expect_category_blocks
      nil
    end
    items = flowing_entries
    events = [:down, :down, :space, :down, :down, :space,
              shrink, verify_focus, grow, verify_focus, shorter, verify_focus, :up, :down, :enter]
    expect(choose(events, items: items, dimensions: [12, 81])).to eq([items[2], items[4]])
    @terminal.frames.each do |frame|
      lines = frame_lines(frame)
      expect(lines[-3]).to start_with('Col ')
      expect(lines[1...-3].join).to match(/>\[[ x]\]/)
    end
    expect(@terminal.frames.last).to include('>[x] c00', '2 selected')
  end

  it 'never displays an orphan header at a viewport bottom or sticky boundary' do
    items = flowing_entries(8, 3)
    choose([:down] * (items.length - 1) + [:enter], items: items, dimensions: [6, 18])
    @terminal.frames.each do |frame|
      body = frame_lines(frame)[1, 2]
      expect(body.last).to include('[ ]')
      expect(body.join).to include('>[ ]')
    end
    expect_bounded_frames([6, 18])
  end

  it 'makes every entry reachable in both directions, including tiny and single-row viewports' do
    items = flowing_entries(8, 3)
    [[12, 81], [6, 38], [5, 18], [3, 8], [2, 3], [1, 1]].each do |dimensions|
      result = choose([:space] + [:down, :space] * (items.length - 1) + [:enter], items: items, dimensions: dimensions)
      expect(result.map(&:object_id)).to eq(items.map(&:object_id))
      expect_category_blocks
      expect_bounded_frames(dimensions)
      expect(choose([:down] * items.length + [:up] * items.length + [:enter], items: items, dimensions: dimensions)).to eq([items.first])
      expect_bounded_frames(dimensions)
    end
  end

  it 'preserves focus and marks through idle shrink/grow and height-only resizes' do
    shrink = ->(terminal) { terminal.dimensions = [6, 18]; nil }
    grow = ->(terminal) { terminal.dimensions = [12, 81]; nil }
    shorter = ->(terminal) { terminal.dimensions = [7, 81]; nil }
    items = flowing_entries
    result = choose([:down] * 5 + [:space, shrink, :down, :space, grow, shorter, :enter], items: items, dimensions: [12, 81])
    expect(result.map(&:object_id)).to eq([items[5].object_id, items[6].object_id])
    expect(@terminal.frames[-5]).to include('>[x] c01')
    expect(@terminal.frames.last).to include('>[x] d00', '2 selected')
    expect(columns.length).to eq(4)
  end

  it 'keeps every focus visible and every planned item intact across varied group sizes and widths' do
    random = Random.new(6201)
    20.times do
      items = flowing_entries(8, 4).select { random.rand(3).positive? }
      items.each { |item| item[:label] += '界' * random.rand(20) }
      dimensions = [random.rand(1..15), [8, 18, 39, 61, 100].sample(random: random)]
      choose([:down] * (items.length - 1) + [:up] * (items.length - 1) + [:enter], items: items, dimensions: dimensions)
      expect(columns.flat_map { |column| column[:indices] }).to eq((0...items.length).to_a)
      expect(columns.length).to be_between(1, 4)
      expect_category_blocks
      @terminal.frames.each { |frame| expect(frame_lines(frame).join).to include('>[ ]') }
      expect_bounded_frames(dimensions)
    end
  end

  it 'interprets pending horizontal arrows using the resized spatial layout' do
    items = flowing_entries
    resize = ->(terminal) { terminal.dimensions = [12, 38]; :right }
    expect(choose([resize, :enter], items: items, dimensions: [12, 81])).to eq([items[6]])
    shrink = ->(terminal) { terminal.dimensions = [7, 18]; :down }
    expect(choose([:down, shrink, :enter], items: items)).to eq([items[2]])
  end

  it 'interprets pending horizontal arrows after a height-only reflow' do
    items = flowing_entries(1, 20)
    shrink = ->(terminal) { terminal.dimensions = [10, 81]; :right }
    expect(choose([:down] * 3 + [shrink, :enter], items: items, dimensions: [16, 81])).to eq([items[13]])
    expect(columns.length).to eq(2)
    expect(@terminal.frames.last).to include('>[ ] a13')
    expect_category_blocks
  end

  it 'prioritizes a header and focused entry whenever two body rows are available' do
    [2, 3, 4].each do |rows|
      choose([:enter], dimensions: [rows, 18])
      lines = frame_lines(@terminal.frames.first)
      expect(lines).to include('MISC', '>[ ] item0')
      expect(lines).to include('Select templates') if rows >= 3
      expect(lines.length).to eq(rows)
    end
  end

  it 'falls back rather than truncating any label that can fit in fewer columns' do
    items = flowing_entries
    items[0][:label] = 'a' * 55
    choose([:enter], items: items, dimensions: [12, 70])
    expect(columns.length).to eq(1)
    expect(frame_lines(@terminal.frames.first)[2]).to eq('>[ ] ' + 'a' * 55)
    expect(frame_lines(@terminal.frames.first)[-2]).to eq('Focus: ' + 'a' * 55)
    expect_bounded_frames([12, 70])
  end

  it 'measures Unicode cells and combining clusters for unclipped multi-column layouts' do
    items = flowing_entries
    items[0][:label] = '界' * 10
    items[4][:label] = "e\u0301" * 10
    choose([:enter], items: items, dimensions: [12, 81])
    expect(columns.map { |column| column[:width] }).to eq([25, 15, 8, 8])
    body = frame_lines(@terminal.frames.first)[1...-3].join
    expect(body).to include('界' * 10, "e\u0301" * 10)
    expect(body).not_to include('…')
    expect_bounded_frames([12, 81])
  end

  it 'clips only an unavoidably wide single column safely and retains a focused-label footer' do
    ['界' * 100, "e\u0301" * 100].each do |label|
      items = entries(2)
      items[0][:label] = label
      choose([:enter], items: items, dimensions: [8, 32])
      expect(columns.length).to eq(1)
      lines = frame_lines(@terminal.frames.first)
      expect(lines[2]).to start_with('>[ ] ')
      expect(lines[2]).to end_with('…')
      expect(lines[-2]).to start_with('Focus: ')
      expect(lines[-2]).to end_with('…')
      expect(lines.all?(&:valid_encoding?)).to be(true)
      expect(lines[2].delete_suffix('…')).to end_with(label.scan(/\X/).first)
      expect_bounded_frames([8, 32])
    end
  end

  it 'packs a large catalog in at most four passes and caches layout across navigation' do
    terminal = PickerTestTerminal.new([:down] * 20 + [:enter], [10, 18])
    picker = described_class.new(flowing_entries(20, 250), terminal: terminal)
    expect(picker).to receive(:flow_columns).with(4, 6).once.and_call_original
    expect(picker).to receive(:flow_columns).with(3, 6).once.and_call_original
    expect(picker).to receive(:flow_columns).with(2, 6).once.and_call_original
    expect(picker).to receive(:flow_columns).with(1, 6).once.and_call_original
    expect(picker.choose.length).to eq(1)
    expect(picker.instance_variable_get(:@columns).flat_map { |column| column[:indices] }).to eq((0...5000).to_a)
  end

  it 'reflows on height-only resize, preserves marked focus and caches unchanged dimensions' do
    items = flowing_entries(1, 20)
    shrink = ->(terminal) { terminal.dimensions = [10, 81]; nil }
    grow = ->(terminal) { terminal.dimensions = [16, 81]; nil }
    original_columns = nil
    verify_tall = lambda do |_terminal|
      expect(columns.map { |column| column[:rows].length }).to eq([22])
      expect(@terminal.frames.last).to include('>[x] a15')
      original_columns = columns
      nil
    end
    verify_short = lambda do |_terminal|
      expect(columns.map { |column| column[:rows].length }).to eq([12, 12])
      expect(columns).not_to equal(original_columns)
      expect(@terminal.frames.last).to include('>[x] a15')
      expect_category_blocks
      nil
    end
    @terminal = PickerTestTerminal.new([:down] * 15 + [:space, verify_tall, shrink, verify_short, :ignore, grow, verify_tall, :enter], [16, 81])
    @picker = described_class.new(items, terminal: @terminal)
    expect(@picker).to receive(:flow_columns).with(4, 12).twice.and_call_original
    expect(@picker).to receive(:flow_columns).with(4, 6).once.and_call_original
    expect(@picker.choose).to eq([items[15]])
  end

  it 'escapes terminal control characters, bidi controls, newlines and invalid Unicode without changing entries' do
    items = [{ name: 'unsafe', label: "bad\e[2J\n\t\x7f\u009b\u202e\u2028\xff".b.force_encoding('UTF-8'), path: '/original' }]
    result = choose([:enter], items: items, dimensions: [8, 160])
    expect(result.first).to equal(items.first)
    text = frame_lines(@terminal.frames.first).join
    expect(text).to include('\\u001B[2J\\u000A\\u0009\\u007F\\u009B\\u202E\\u2028')
    expect(text).not_to match(/[\e\n\t\u202e\u2028]/)
    expect(text).to include('�')
  end

  it 'uppercases, sanitizes and clips long Unicode and malicious category headings without modifying entries' do
    unsafe = "bad\e[2J\n\t\x7f\u009b\u202e\u2028\xff".b.force_encoding('UTF-8')
    items = entries(1)
    items[0][:category] = unsafe
    expect(choose([:enter], items: items, dimensions: [8, 160]).first).to equal(items[0])
    header = frame_lines(@terminal.frames.first)[1]
    expect(header).to include('BAD\\u001B[2J\\u000A\\u0009\\u007F\\u009B\\u202E\\u2028�')
    expect(header).not_to match(/[\e\n\t\u202e\u2028]/)
    expect(items[0][:category]).to eq(unsafe)
    ['界' * 100, "e\u0301" * 100].each do |category|
      items[0][:category] = category
      choose([:enter], items: items, dimensions: [4, 12])
      header = frame_lines(@terminal.frames.first)[1]
      expect(header).to end_with('…')
      expect(header).to start_with(category[0].upcase)
      expect(header.valid_encoding?).to be(true)
      expect(Unicode::DisplayWidth.of(header)).to be <= 11
    end
  end

  [:cancel, :eof].each do |key|
    it "raises CLIError and restores the terminal on #{key}" do
      expect { choose([key]) }.to raise_error(FoobarTemplates::CLIError, /cancelled/)
      expect(@terminal.writes.first).to eq(described_class::ENTER_SCREEN)
      expect(@terminal.writes.last).to eq(described_class::LEAVE_SCREEN)
      expect(@terminal.restored).to be(true)
      expect(@terminal.raw_active).to be(false)
    end
  end

  it 'restores the terminal on successful selection, arbitrary errors and interrupts' do
    choose([:enter])
    expect(@terminal.writes.last).to eq(described_class::LEAVE_SCREEN)
    expect(@terminal.restored).to be(true)
    expect { choose([RuntimeError.new('failed')]) }.to raise_error(RuntimeError, 'failed')
    expect(@terminal.writes.last).to eq(described_class::LEAVE_SCREEN)
    expect(@terminal.restored).to be(true)
    expect { choose([Interrupt.new]) }.to raise_error(FoobarTemplates::CLIError, /cancelled/)
    expect(@terminal.writes.last).to eq(described_class::LEAVE_SCREEN)
    expect(@terminal.restored).to be(true)
  end

  it 'restores after a rendering failure and converts terminal IO errors to CLIError' do
    terminal = PickerTestTerminal.new([], [10, 49])
    allow(terminal).to receive(:size).and_raise(IOError, 'broken terminal')
    expect { described_class.new(entries, terminal: terminal).choose }.to raise_error(FoobarTemplates::CLIError, /broken terminal/)
    expect(terminal.writes.last).to eq(described_class::LEAVE_SCREEN)
    expect(terminal.restored).to be(true)
  end

  it 'rejects an empty catalog without opening a terminal' do
    expect { choose([], items: []) }.to raise_error(FoobarTemplates::CLIError, /No templates/)
    expect(@terminal.writes).to be_empty
  end

  it 'rejects redirected input or output without emitting terminal sequences' do
    [true, false].each do |input_tty|
      input, output = StringIO.new, StringIO.new
      allow(input).to receive(:tty?).and_return(input_tty)
      allow(output).to receive(:tty?).and_return(!input_tty)
      expect { described_class.new(entries, input: input, output: output).choose }.to raise_error(FoobarTemplates::CLIError, /interactive/)
      expect(output.string).to eq('')
    end
  end

  describe described_class::Terminal do
    {
      "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
      "\eOA" => :up, "\e[1;5C" => :right, "\e[3~" => :ignore,
      'h' => :left, 'j' => :down, 'k' => :up, 'l' => :right,
      ' ' => :space, "\r" => :enter, "\n" => :enter,
      'q' => :cancel, 'Q' => :cancel, "\x03" => :cancel, "\x04" => :eof,
      'z' => :ignore, "\e" => :cancel
    }.each do |bytes, expected|
      it "decodes #{bytes.inspect} as #{expected}" do
        reader, writer = IO.pipe
        writer.write(bytes)
        expect(described_class.new(reader, StringIO.new).read_key(timeout: 0.1)).to eq(expected)
      ensure
        reader&.close
        writer&.close
      end
    end

    it 'distinguishes idle timeout from EOF' do
      reader, writer = IO.pipe
      terminal = described_class.new(reader, StringIO.new)
      expect(terminal.read_key(timeout: 0.001)).to be_nil
      writer.close
      expect(terminal.read_key(timeout: 0.1)).to eq(:eof)
    ensure
      reader&.close
      writer&.close unless writer&.closed?
    end
  end

  describe 'real PTY lifecycle' do
    { "\e[C\r" => :selected, "hjkl\r" => :selected, 'q' => :cancelled, "\x03" => :cancelled, "\e" => :cancelled }.each do |keys, outcome|
      it "uses raw mode and restores echo, cursor and alternate screen for #{keys.inspect}" do
        master, slave = PTY.open
        slave.winsize = [10, 60]
        original_echo = slave.echo?
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('TERM').and_return('xterm')
        items = categorized_entries
        picker = described_class.new(items, input: slave, output: slave)
        worker = Thread.new do
          begin
            picker.choose
          rescue FoobarTemplates::CLIError => error
            error
          end
        end
        worker.report_on_exception = false
        screen = +''
        Timeout.timeout(5) { screen << master.readpartial(4096) until screen.include?('columns') }
        expect(screen).to include(described_class::ENTER_SCREEN)
        expect(slave.echo?).to be(false)
        master.write(keys)
        result = Timeout.timeout(5) { worker.value }
        Timeout.timeout(5) { screen << master.readpartial(4096) until screen.include?(described_class::LEAVE_SCREEN) }
        expect(slave.echo?).to eq(original_echo)
        if outcome == :selected
          expect(result).to eq([items[3]])
        else
          expect(result).to be_a(FoobarTemplates::CLIError)
        end
      ensure
        worker&.kill if worker&.alive?
        worker&.join
        master&.close
        slave&.close
      end
    end
  end
end