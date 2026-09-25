require 'spec_helper'
require 'tmpdir'
require 'foobar_templates/core/template_source'

RSpec.describe FoobarTemplates::Core::TemplateSource do
  around do |example|
    Dir.mktmpdir('template-source') do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  before do
    allow(Dir).to receive(:children).and_call_original
  end

  def write_file(path, content = '')
    absolute = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
  end

  it 'separates eligible files and directories, excluding only root metadata from files' do
    write_file('foobar.yml')
    write_file('nested/foobar.yml')
    write_file('.hidden')
    write_file('.git/objects/hidden')
    write_file('nested/.git/hidden')
    FileUtils.mkdir_p(File.join(@root, 'empty'))
    source = described_class.new(@root, strict: true)

    expect(source.relative_paths).to contain_exactly('foobar.yml', 'nested', 'nested/foobar.yml', '.hidden', 'empty')
    expect(source.files).to contain_exactly('nested/foobar.yml', '.hidden')
    expect(source.directories).to contain_exactly('nested', 'empty')
  end

  it 'prunes ignored subtrees and handles spaces/newlines with batched NUL input' do
    system('git', '-C', @root, 'init', '-q', exception: true)
    write_file('.gitignore', "vendor/\n*.ignored\n")
    write_file('vendor/package/file')
    write_file("line\nbreak.ignored")
    write_file('space name.ignored')
    write_file("line\nbreak.txt")
    write_file('src/file')
    expect(Dir).not_to receive(:children).with(File.join(@root, 'vendor'))
    calls = []
    allow(Open3).to receive(:capture3).and_wrap_original do |method, *args, **options|
      calls << [args, options]
      method.call(*args, **options)
    end

    expect(described_class.new(@root, strict: true).files).to contain_exactly('.gitignore', "line\nbreak.txt", 'src/file')
    expect(calls.length).to eq(2)
    expect(calls.first.first).to eq(['git', '-C', @root, 'check-ignore', '-z', '--stdin'])
    expect(calls.first.last[:stdin_data].split("\x00")).to include("line\nbreak.ignored", 'space name.ignored', 'vendor')
  end

  it 'retains legacy file symlink behavior by default' do
    write_file('real', 'foo-bar')
    File.symlink('real', File.join(@root, 'link'))
    expect(described_class.new(@root).files).to contain_exactly('real', 'link')
  end

  %w[file directory dangling loop].each do |kind|
    it "rejects a #{kind} symlink without traversing it in strict mode" do
      write_file('real') if kind == 'file'
      FileUtils.mkdir_p(File.join(@root, 'real')) if kind == 'directory'
      target = kind == 'loop' ? '.' : 'real'
      link = File.join(@root, 'link')
      File.symlink(target, link)
      expect(Dir).not_to receive(:children).with(link)
      expect { described_class.new(@root, strict: true).relative_paths }
        .to raise_error(FoobarTemplates::CLIError, /Unsupported template source path.*link/)
    end
  end

  it 'rejects a symlink at the source root' do
    FileUtils.mkdir_p(File.join(@root, 'real'))
    File.symlink('real', File.join(@root, 'link'))
    expect { described_class.new(File.join(@root, 'link'), strict: true).files }
      .to raise_error(FoobarTemplates::CLIError, /symlinks/)
  end

  it 'rejects symlink source ancestors, including before a dot-dot component' do
    FileUtils.mkdir_p(File.join(@root, 'real/child'))
    File.symlink('real', File.join(@root, 'link'))
    ['link/child', 'link/../real/child'].each do |relative|
      expect { described_class.new(File.join(@root, relative), strict: true).files }
        .to raise_error(FoobarTemplates::CLIError, /symlinks/)
    end
  end

  it 'rejects special files without opening them' do
    fifo = File.join(@root, 'pipe')
    system('mkfifo', fifo, exception: true)
    expect { described_class.new(@root, strict: true).files }
      .to raise_error(FoobarTemplates::CLIError, /special files/)
    expect { described_class.new(fifo, strict: true).files }
      .to raise_error(FoobarTemplates::CLIError, /source ancestors must be directories/)
  end

  it 'reports missing roots and regular-file roots as CLI errors in strict mode' do
    write_file('file')
    %w[missing file].each do |path|
      expect { described_class.new(File.join(@root, path), strict: true).directories }
        .to raise_error(FoobarTemplates::CLIError)
    end
  end
end