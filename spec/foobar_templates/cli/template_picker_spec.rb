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
    described_class.new(items, terminal: @terminal).choose
  end

  def frame_lines(frame)
    frame.sub("\e[H\e[2J", '').split(/\e\[\d+;1H/).drop(1)
  end

  it 'confirms focus if nothing is marked and returns original entry hashes' do
    items = entries
    expect(choose([:right, :enter], items: items).first).to equal(items[1])
  end

  it 'toggles in place, confirms only marked entries, and returns display rather than toggle order' do
    items = entries
    result = choose([:down, :space, :up, :space, :right, :enter], items: items)
    expect(result).to eq([items[0], items[3]])
    expect(@terminal.frames[2]).to include('>[x] item3')
    expect(@terminal.frames.last).to include('2 selected')
  end

  it 'unmarks without moving focus and falls back to focus when every mark is removed' do
    expect(choose([:right, :space, :space, :enter])).to eq([entries[1]])
  end

  it 'uses row-major spatial movement for all four arrows' do
    expect(choose([:right, :down, :left, :up, :enter])).to eq([entries[0]])
    expect(choose([:right, :down, :enter])).to eq([entries[4]])
    expect(frame_lines(@terminal.frames.first)[1]).to include('item0', 'item1', 'item2')
  end

  it 'does not wrap horizontally or vertically at any edge or into an incomplete last row' do
    expect(choose([:left, :up, :enter])).to eq([entries[0]])
    expect(choose([:right, :right, :right, :enter])).to eq([entries[2]])
    expect(choose([:down, :left, :enter])).to eq([entries[3]])
    expect(choose([:down, :down, :right, :down, :enter])).to eq([entries[7]])
    expect(choose([:down, :down, :down, :down, :right, :enter])).to eq([entries[9]])
  end

  it 'scrolls down and back up to keep focus visible' do
    expect(choose([:down, :down, :down, :up, :up, :up, :enter], dimensions: [6, 49])).to eq([entries[0]])
    expect(@terminal.frames[3]).to include('item9', 'rows 3-4/4')
    expect(@terminal.frames.last).to include('item0', 'rows 1-2/4')
  end

  it 'reflows on an idle timeout resize without losing focus or selections' do
    resize = ->(terminal) { terminal.dimensions = [7, 18]; nil }
    result = choose([:down, :right, :space, resize, :down, :space, :enter])
    expect(result).to eq([entries[4], entries[5]])
    expect(@terminal.frames[-3]).to include('>[x] item4')
    expect(frame_lines(@terminal.frames.last).all? { |line| Unicode::DisplayWidth.of(line) <= 17 }).to be(true)
  end

  it 'also reflows when dimensions change with a pending arrow' do
    resize = ->(terminal) { terminal.dimensions = [7, 18]; :down }
    expect(choose([:right, resize, :enter])).to eq([entries[2]])
  end

  it 'falls back to one column on narrow terminals and clips even very small screens' do
    [[5, 12], [3, 8], [2, 3], [1, 1]].each do |dimensions|
      expect(choose([:right, :down, :enter], dimensions: dimensions)).to eq([entries[1]])
      @terminal.frames.each do |frame|
        lines = frame_lines(frame)
        expect(lines.length).to be <= dimensions[0]
        expect(lines.all? { |line| Unicode::DisplayWidth.of(line) < dimensions[1] }).to be(true)
      end
    end
  end

  it 'uses multiple columns despite long labels and truncates Unicode by display cells' do
    items = entries(6)
    items[0][:label] = '界' * 100
    items[1][:label] = "e\u0301" * 100
    choose([:enter], items: items, dimensions: [8, 81])
    lines = frame_lines(@terminal.frames.first)
    expect(lines[1]).to include('界', "e\u0301", '…')
    expect(lines.all? { |line| Unicode::DisplayWidth.of(line) <= 80 }).to be(true)
    expect(lines[-2]).to start_with('Focus: 界')
  end

  it 'keeps the full focused label in the footer when it fits there but not in a grid cell' do
    items = entries(3)
    items[0][:label] = 'a' * 45
    choose([:enter], items: items, dimensions: [8, 81])
    expect(frame_lines(@terminal.frames.first)[1]).to include('…')
    expect(frame_lines(@terminal.frames.first)[-2]).to eq("Focus: #{'a' * 45}")
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
    { "\e[C\r" => :selected, 'q' => :cancelled, "\x03" => :cancelled, "\e" => :cancelled }.each do |keys, outcome|
      it "uses raw mode and restores echo, cursor and alternate screen for #{keys.inspect}" do
        master, slave = PTY.open
        slave.winsize = [10, 60]
        original_echo = slave.echo?
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('TERM').and_return('xterm')
        items = entries
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
        Timeout.timeout(5) { screen << master.readpartial(4096) until screen.include?('Arrows move') }
        expect(screen).to include(described_class::ENTER_SCREEN)
        expect(slave.echo?).to be(false)
        master.write(keys)
        result = Timeout.timeout(5) { worker.value }
        Timeout.timeout(5) { screen << master.readpartial(4096) until screen.include?(described_class::LEAVE_SCREEN) }
        expect(slave.echo?).to eq(original_echo)
        if outcome == :selected
          expect(result).to eq([items[1]])
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