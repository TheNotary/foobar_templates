require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'foobar_templates/core/merger'

RSpec.describe FoobarTemplates::Core::Merger do
  let(:input) { StringIO.new }
  let(:output) { StringIO.new }
  let(:configurator) { FoobarTemplates::Configurator.new }

  around do |example|
    Dir.mktmpdir('core-merger-') do |sandbox|
      @sandbox = File.realpath(sandbox)
      @home = File.join(@sandbox, 'home')
      @target = File.join(@sandbox, 'my-app')
      FileUtils.mkdir_p([@home, @target])
      environment = {
        'HOME' => @home,
        'GIT_CONFIG_GLOBAL' => File.join(@home, '.gitconfig'),
        'GIT_CONFIG_SYSTEM' => File::NULL,
        'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_CONFIG_COUNT' => '0',
        'GIT_CONFIG' => nil, 'GIT_DIR' => nil, 'GIT_COMMON_DIR' => nil,
        'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil,
      }
      previous = environment.to_h { |key, _| [key, ENV[key]] }
      begin
        ENV.update(environment)
        write_file(@home, '.foobar/config', YAML.dump('always_perform_git_init' => true))
        Dir.chdir(@target) { example.run }
      ensure
        ENV.update(previous)
      end
    end
  end

  before do
    # Keep enumeration, rendering and filesystem operations real. Only identity
    # lookup is stubbed, so neither machine Git settings nor a user's config leak in.
    allow(FoobarTemplates::Core::InterpolationContext).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap do |context|
        allow(context).to receive(:`).with('git config user.name').and_return("Merge Tester\n")
        allow(context).to receive(:`).with('git config user.email').and_return("merge@example.com\n")
      end
    end
  end

  def write_file(root, relative, bytes = '', mode: nil)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    File.chmod(mode, path) if mode
    path
  end

  def template(name, files = {}, metadata: {}, **file_entries)
    root = File.join(@sandbox, 'templates', name)
    write_file(root, 'foobar.yml', YAML.dump(metadata))
    files.merge(file_entries).each { |relative, bytes| write_file(root, relative, bytes) }
    { name: name, label: "#{name} (fixture)", path: root }
  end

  def merger(*entries, **options)
    described_class.new(target: @target, templates: entries, configurator: configurator,
                        input: input, output: output, **options)
  end

  # Record names, inode, mode, mtime and bytes, including empty directories and
  # dangling links, without following links or reading special files.
  def tree_state(root, relative = '.')
    path = File.join(root, relative)
    stat = File.lstat(path)
    content = if stat.symlink?
                File.readlink(path)
              elsif stat.file?
                File.binread(path)
              end
    state = { relative => [stat.ftype, stat.ino, stat.mode, stat.mtime, content] }
    if stat.directory?
      Dir.children(path).sort.each do |child|
        child_relative = relative == '.' ? child : File.join(relative, child)
        state.merge!(tree_state(root, child_relative))
      end
    end
    state
  end

  def expect_preflight_failure(engine, message, error: FoobarTemplates::CLIError)
    before = tree_state(@target)
    expect { engine.run { raise 'Preflight must not ask for approval' } }.to raise_error(error, message)
    expect(tree_state(@target)).to eq(before)
  end

  describe 'ordered application and result counts' do
    it 'counts creates, rendered equality, approvals and skips without changing unrelated files' do
      entry = template('base', 'a-new' => 'foo-bar', 'b-same' => 'foo-bar',
                               'c-overwrite' => 'incoming', 'd-skip' => 'incoming')
      write_file(@target, 'b-same', 'my-app', mode: 0o600)
      overwrite = write_file(@target, 'c-overwrite', 'local', mode: 0o600)
      skipped = write_file(@target, 'd-skip', 'local', mode: 0o640)
      write_file(@target, 'unrelated', 'leave me alone')
      File.chmod(0o751, File.join(entry[:path], 'a-new'))
      File.chmod(0o750, File.join(entry[:path], 'c-overwrite'))
      [File.join(@target, 'b-same'), skipped].each do |path|
        File.utime(Time.at(1_000_000), Time.at(1_000_000), path)
      end
      before = tree_state(@target)
      source_before = tree_state(entry[:path])
      decisions = []

      counts = merger(entry).run(interactive: true) do |candidate, local|
        decisions << [candidate.relative_path, candidate.template, candidate.bytes, local]
        candidate.relative_path == 'c-overwrite'
      end

      expect(counts).to eq(created: 1, overwritten: 1, unchanged: 1, skipped: 1)
      expect(decisions).to eq([
        ['c-overwrite', entry, 'incoming', 'local'], ['d-skip', entry, 'incoming', 'local'],
      ])
      expect(File.binread(File.join(@target, 'a-new'))).to eq('my-app')
      expect(File.stat(File.join(@target, 'a-new')).mode & 0o777).to eq(0o751)
      expect(File.binread(overwrite)).to eq('incoming')
      expect(File.stat(overwrite).mode & 0o777).to eq(0o750)
      %w[b-same d-skip unrelated].each { |path| expect(tree_state(@target)[path]).to eq(before[path]) }
      expect(tree_state(entry[:path])).to eq(source_before)
    end

    it 'honors supplied template order and lexical source order, comparing against accepted writes' do
      first = template('z-first', 'z-file' => 'first z', 'a-file' => 'first a')
      second = template('a-second', 'z-file' => 'second z', 'a-file' => 'second a')
      third = template('third', 'a-file' => 'third a')
      seen = []

      counts = merger(first, second, third).run(interactive: true) do |candidate, local|
        seen << [candidate.template[:name], candidate.relative_path, local, candidate.bytes]
        candidate.relative_path == 'z-file'
      end

      expect(seen).to eq([
        ['a-second', 'a-file', 'first a', 'second a'],
        ['a-second', 'z-file', 'first z', 'second z'],
        ['third', 'a-file', 'first a', 'third a'],
      ])
      expect(counts).to eq(created: 2, overwritten: 1, unchanged: 0, skipped: 2)
      expect(File.binread(File.join(@target, 'a-file'))).to eq('first a')
      expect(File.binread(File.join(@target, 'z-file'))).to eq('second z')
    end

    it 'accepts identical cross-template rendered collisions without a terminal or mode changes' do
      first = template('first', 'foo-bar' => 'foo-bar')
      second = template('second', 'my-app' => 'my-app')
      File.chmod(0o700, File.join(first[:path], 'foo-bar'))
      File.chmod(0o644, File.join(second[:path], 'my-app'))

      counts = merger(first, second).run { raise 'Identical content must not prompt' }

      expect(counts).to eq(created: 1, overwritten: 0, unchanged: 1, skipped: 0)
      expect(File.stat(File.join(@target, 'my-app')).mode & 0o777).to eq(0o700)
    end

    it 'rejects two source files transformed to the same destination even when their bytes match' do
      entry = template('collision', 'foo-bar.txt' => 'same', 'my-app.txt' => 'same', 'a-new' => 'new')
      expect_preflight_failure(merger(entry), /Rendered path collision.*foo-bar\.txt.*my-app\.txt/)
    end

    it 'rejects transformed directory collisions before combining their distinct children' do
      entry = template('collision', 'foo-bar/one' => 'one', 'my-app/two' => 'two')
      expect_preflight_failure(merger(entry), /Rendered path collision.*foo-bar.*my-app/)
    end
  end

  describe 'selection and complete preflight' do
    it 'reports every template missing the selected source file before writing from a valid one' do
      valid = template('valid', 'src/foo-bar.rb' => 'foo-bar')
      missing_one = template('missing-one', 'other' => 'one')
      missing_two = template('missing-two', 'other' => 'two')

      expect_preflight_failure(
        merger(valid, missing_one, missing_two, selected_file: 'src/foo-bar.rb'),
        /missing-one: src\/foo-bar\.rb.*missing-two: src\/foo-bar\.rb/
      )
    end

    it 'selects the unrendered source path in every template and excludes unrelated directories and configuration' do
      first = template('first', 'src/foo-bar.rb' => 'foo-bar', 'unused' => 'FOO_K8S_DOMAIN')
      second = template('second', 'src/foo-bar.rb' => 'my-app')
      FileUtils.mkdir_p(File.join(first[:path], 'empty'))
      expect(input).not_to receive(:gets)

      counts = merger(first, second, selected_file: 'src/foo-bar.rb').run

      expect(counts).to eq(created: 1, overwritten: 0, unchanged: 1, skipped: 0)
      expect(tree_state(@target).keys).to eq(['.', 'src', 'src/my-app.rb'])
      expect(File.binread(File.join(@target, 'src/my-app.rb'))).to eq('my-app')
    end

    %w[foobar.yml empty ignored].each do |selection|
      it "does not treat excluded metadata, directories or ignored files as selected files: #{selection}" do
        entry = template('base', '.gitignore' => "ignored\n", 'ignored' => 'hidden', 'a-new' => 'new')
        FileUtils.mkdir_p(File.join(entry[:path], 'empty'))
        system('git', '-C', entry[:path], 'init', '-q', exception: true)
        expect_preflight_failure(merger(entry, selected_file: selection), /Selected file not found or excluded/)
      end
    end

    it 'validates required settings in later templates before creating earlier files or empty directories' do
      first = template('first', 'a-new' => 'new')
      FileUtils.mkdir_p(File.join(first[:path], 'empty'))
      second = template('second', 'needs-domain' => 'FOO_REGISTRY_DOMAIN')
      expect(input).not_to receive(:gets)
      expect(configurator).not_to receive(:set_domain)
      expect_preflight_failure(merger(first, second), /Missing required template configuration: registry_domain/)
    end

    it 'preflights every noninteractive local conflict without creating even empty directories' do
      entry = template('base', 'a-new' => 'new', 'z-conflict' => 'incoming')
      FileUtils.mkdir_p(File.join(entry[:path], 'empty/nested'))
      write_file(@target, 'z-conflict', 'local')
      expect_preflight_failure(merger(entry), /z-conflict.*No destination files were written/,
                               error: described_class::ConflictError)
    end

    it 'preflights differing virtual destinations across templates even when the target is empty' do
      first = template('first', 'foo-bar' => 'first', 'a-new' => 'new')
      second = template('second', 'my-app' => 'second')
      FileUtils.mkdir_p(File.join(first[:path], 'empty'))
      expect_preflight_failure(merger(first, second), /my-app.*No destination files were written/,
                               error: described_class::ConflictError)
    end

    [:file_first, :directory_first].each do |order|
      it "rejects cross-template file/directory collisions with #{order}" do
        file = template('file', 'foo-bar' => 'file', 'a-new' => 'new')
        directory = template('directory', 'my-app/child' => 'child')
        entries = order == :file_first ? [file, directory] : [directory, file]
        expect_preflight_failure(merger(*entries), /File\/directory collision.*my-app/)
      end
    end

    it 'rejects a cross-template file collision with an empty transformed directory' do
      first = template('first', 'foo-bar' => 'file')
      second = template('second')
      FileUtils.mkdir_p(File.join(second[:path], 'my-app'))
      expect_preflight_failure(merger(first, second), /File\/directory collision.*my-app/)
    end
  end

  describe 'unsupported sources and destinations' do
    %w[file directory dangling loop metadata].each do |kind|
      it "rejects a source #{kind} symlink before any earlier template is written" do
        first = template('first', 'a-new' => 'new')
        unsafe = template('unsafe', 'safe' => 'safe')
        outside = File.join(@sandbox, 'outside')
        FileUtils.mkdir_p(outside)
        external_file = write_file(outside, 'file', 'external')
        link_target = { 'file' => external_file, 'directory' => outside,
                        'dangling' => File.join(outside, 'missing'), 'loop' => '.',
                        'metadata' => external_file }.fetch(kind)
        link = File.join(unsafe[:path], kind == 'metadata' ? 'foobar.yml' : 'z-link')
        File.unlink(link) if kind == 'metadata'
        File.symlink(link_target, link)
        outside_before = tree_state(outside)

        expect_preflight_failure(merger(first, unsafe), /Unsupported template source path.*symlinks/)
        expect(tree_state(outside)).to eq(outside_before)
      end
    end

    it 'rejects an unselected unsafe source rather than following it during discovery' do
      entry = template('base', 'selected' => 'safe')
      File.symlink('missing', File.join(entry[:path], 'unselected'))
      expect_preflight_failure(merger(entry, selected_file: 'selected'), /Unsupported template source path/)
    end

    [:root, :ancestor].each do |location|
      it "rejects a symlink at the source #{location}" do
        entry = template('base', 'a-new' => 'new')
        link = File.join(@sandbox, 'source-link')
        File.symlink(location == :root ? entry[:path] : File.dirname(entry[:path]), link)
        path = location == :root ? link : File.join(link, 'base')
        expect_preflight_failure(merger(entry.merge(path: path)), /Unsupported template source path.*symlinks/)
      end
    end

    it 'rejects a source symlink ancestor before normalizing a following dot-dot component' do
      entry = template('base', 'a-new' => 'new')
      FileUtils.mkdir_p(File.join(@sandbox, 'external'))
      File.symlink(File.join(@sandbox, 'external'), File.join(@sandbox, 'templates', 'link'))
      unsafe_path = File.join(@sandbox, 'templates', 'link', '..', 'base')
      expect_preflight_failure(merger(entry.merge(path: unsafe_path)), /symlinks/)
    end

    it 'rejects a source FIFO without opening it or writing an earlier template' do
      first = template('first', 'a-new' => 'new')
      unsafe = template('unsafe', 'safe' => 'safe')
      fifo = File.join(unsafe[:path], 'pipe')
      system('mkfifo', fifo, exception: true)
      allow(File).to receive(:binread).and_call_original
      expect(File).not_to receive(:binread).with(fifo)
      expect_preflight_failure(merger(first, unsafe), /special files/)
    end

    %w[file ancestor dangling].each do |kind|
      it "rejects a destination #{kind} symlink and leaves the external tree unchanged" do
        outside = File.join(@sandbox, 'outside')
        external = write_file(outside, 'file', 'external')
        relative = kind == 'ancestor' ? 'z-link/file' : 'z-link'
        entry = template('base', 'a-new' => 'new', relative => 'incoming')
        destination = File.join(@target, 'z-link')
        link_target = kind == 'ancestor' ? outside : (kind == 'file' ? external : File.join(outside, 'missing'))
        File.symlink(link_target, destination)
        outside_before = tree_state(outside)

        expect_preflight_failure(merger(entry), /Unsupported destination path/)
        expect(tree_state(outside)).to eq(outside_before)
      end
    end

    [:root, :ancestor].each do |location|
      it "rejects a symlink at the target #{location}" do
        entry = template('base', 'a-new' => 'new')
        link = File.join(@sandbox, 'target-link')
        File.symlink(location == :root ? @target : @sandbox, link)
        path = location == :root ? link : File.join(link, 'my-app')
        expect_preflight_failure(merger(entry, target: path), /Unsupported destination ancestor.*symlinks/)
      end
    end

    it 'rejects a destination FIFO without opening it' do
      entry = template('base', 'a-new' => 'new', 'pipe' => 'incoming')
      fifo = File.join(@target, 'pipe')
      system('mkfifo', fifo, exception: true)
      allow(File).to receive(:binread).and_call_original
      expect(File).not_to receive(:binread).with(fifo)
      expect_preflight_failure(merger(entry), /Unsupported destination path/)
    end

    [:file_over_directory, :directory_over_file, :file_ancestor].each do |kind|
      it "rejects an existing destination type conflict: #{kind}" do
        relative = kind == :file_ancestor ? 'z-path/child' : 'z-path'
        entry = template('base', 'a-new' => 'new', relative => 'incoming')
        if kind == :file_over_directory
          FileUtils.mkdir_p(File.join(@target, 'z-path'))
        else
          write_file(@target, 'z-path', 'local')
          if kind == :directory_over_file
            File.unlink(File.join(entry[:path], 'z-path'))
            FileUtils.mkdir_p(File.join(entry[:path], 'z-path'))
          end
        end
        expect_preflight_failure(merger(entry), /Unsupported destination path or file\/directory collision/)
      end
    end

    [:same_root, :source_inside_target, :target_inside_source].each do |overlap|
      it "rejects overlapping roots: #{overlap}" do
        source = case overlap
                 when :same_root then @target
                 when :source_inside_target then File.join(@target, 'source')
                 when :target_inside_source then @sandbox
                 end
        write_file(source, 'a-new', 'new')
        entry = { name: 'overlapping', path: source }
        expect_preflight_failure(merger(entry), /source and destination overlap/)
      end
    end
  end

  describe 'filesystem fidelity and lifecycle isolation' do
    it 'respects source ignores but not target ignores, preserves empty directories, and never runs hooks' do
      entry = template('base', {
        '.gitignore' => "vendor/\n*.ignored\n",
        '.hidden' => 'keep', 'nested/foobar.yml' => 'nested metadata is content',
        'included' => 'foo-bar', 'vendor/deep/file' => 'ignored', 'secret.ignored' => 'ignored',
        'nested/.git/private' => 'excluded',
      }, metadata: { 'bootstrap_command' => 'touch BOOTSTRAPPED' })
      system('git', '-C', entry[:path], 'init', '-q', exception: true)
      system('git', '-C', @target, 'init', '-q', exception: true)
      write_file(@target, '.git/info/exclude', "included\n")
      FileUtils.mkdir_p(File.join(entry[:path], 'empty/nested'))
      engine = merger(entry)
      source_before = tree_state(entry[:path])
      git_before = tree_state(File.join(@target, '.git'))
      config_before = tree_state(@home)
      expect(FoobarTemplates::CLI::TemplateGenerator).not_to receive(:new)
      expect(engine).not_to receive(:system)
      expect(engine).not_to receive(:`)

      expect(engine.run).to eq(created: 4, overwritten: 0, unchanged: 0, skipped: 0)

      expect(File.binread(File.join(@target, 'included'))).to eq('my-app')
      expect(File.binread(File.join(@target, '.hidden'))).to eq('keep')
      expect(File.binread(File.join(@target, 'nested/foobar.yml'))).to eq('nested metadata is content')
      expect(Dir.children(File.join(@target, 'empty/nested'))).to be_empty
      %w[vendor secret.ignored foobar.yml BOOTSTRAPPED nested/.git].each do |path|
        expect(File.exist?(File.join(@target, path))).to be(false)
      end
      expect(tree_state(entry[:path])).to eq(source_before)
      expect(tree_state(File.join(@target, '.git'))).to eq(git_before)
      expect(tree_state(@home)).to eq(config_before)
    end

    it 'accepts a template containing only empty directories with zero file counts' do
      entry = template('empty')
      FileUtils.mkdir_p(File.join(entry[:path], 'foo-bar/nested'))
      expect(merger(entry).run).to eq(created: 0, overwritten: 0, unchanged: 0, skipped: 0)
      expect(tree_state(@target).keys).to eq(['.', 'my-app', 'my-app/nested'])
    end

    { 'binary' => "foo-bar\0FOO_K8S_DOMAIN\xff".b,
      'invalid UTF-8' => "foo-bar\xffFOO_REGISTRY_DOMAIN".b }.each do |kind, bytes|
      it "creates, compares and overwrites #{kind} as opaque bytes without requesting domains" do
        entry = template('opaque', 'foo-bar.bin' => bytes)
        expect(input).not_to receive(:gets)
        expect(configurator).not_to receive(:set_domain)
        expect(merger(entry).run).to eq(created: 1, overwritten: 0, unchanged: 0, skipped: 0)
        destination = File.join(@target, 'my-app.bin')
        expect(File.binread(destination)).to eq(bytes)
        before = tree_state(@target)
        expect(merger(entry).run { raise 'Opaque equality must not prompt' })
          .to eq(created: 0, overwritten: 0, unchanged: 1, skipped: 0)
        expect(tree_state(@target)).to eq(before)
        File.binwrite(destination, "different\xff\0".b)
        decisions = []
        counts = merger(entry).run(interactive: true) do |candidate, local|
          decisions << [candidate.bytes, local]
          true
        end
        expect(decisions).to eq([[bytes, "different\xff\0".b]])
        expect(counts).to eq(created: 0, overwritten: 1, unchanged: 0, skipped: 0)
        expect(File.binread(destination)).to eq(bytes)
        expect(File.binread(File.join(entry[:path], 'foo-bar.bin'))).to eq(bytes)
      end
    end
  end

  describe 'changes during conflict confirmation' do
    [true, false].each do |second_approval|
      it "re-prompts for changed destination bytes and honors a second #{second_approval} decision" do
        entry = template('base', 'file' => 'incoming')
        destination = write_file(@target, 'file', 'original')
        observed = []
        staged_paths = []
        counts = merger(entry).run(interactive: true) do |candidate, local|
          observed << local
          staged_paths << candidate.staged_path
          if observed.length == 1
            File.binwrite(destination, 'edited during confirmation')
            true
          else
            raise 'Unexpected third prompt' if observed.length > 2
            second_approval
          end
        end

        expect(observed).to eq(['original', 'edited during confirmation'])
        expect(counts).to eq(created: 0, overwritten: second_approval ? 1 : 0,
                             unchanged: 0, skipped: second_approval ? 0 : 1)
        expect(File.binread(destination)).to eq(second_approval ? 'incoming' : 'edited during confirmation')
        expect(Dir.children(@target)).to eq(['file'])
        staged_paths.each { |path| expect(File.exist?(File.dirname(path))).to be(false) }
      end
    end

    it 'does not replace a file changed to a symlink during approval or modify the external file' do
      entry = template('base', 'file' => 'incoming')
      destination = write_file(@target, 'file', 'original')
      outside = write_file(@sandbox, 'external', 'external')
      expect do
        merger(entry).run(interactive: true) do |_candidate, _local|
          File.unlink(destination)
          File.symlink(outside, destination)
          true
        end
      end.to raise_error(FoobarTemplates::CLIError, /Unsupported destination path/)
      expect(File.symlink?(destination)).to be(true)
      expect(File.binread(outside)).to eq('external')
      expect(Dir.children(@target)).to eq(['file'])
    end

    it 'uses prepared bytes even if the source is edited while confirming a conflict' do
      entry = template('base', 'file' => 'prepared')
      destination = write_file(@target, 'file', 'local')
      counts = merger(entry).run(interactive: true) do |candidate, _local|
        File.binwrite(File.join(entry[:path], 'file'), 'subsequent source edit')
        expect(candidate.bytes).to eq('prepared')
        true
      end
      expect(counts).to eq(created: 0, overwritten: 1, unchanged: 0, skipped: 0)
      expect(File.binread(destination)).to eq('prepared')
    end

    it 'cleans staging on callback failure while retaining completed writes and the unapproved destination' do
      entry = template('base', 'a-new' => 'new', 'z-conflict' => 'incoming')
      write_file(@target, 'z-conflict', 'local')
      staging = nil
      expect do
        merger(entry).run(interactive: true) do |candidate, _local|
          staging = File.dirname(candidate.staged_path)
          raise FoobarTemplates::CLIError, 'cancelled by caller'
        end
      end.to raise_error(FoobarTemplates::CLIError, 'cancelled by caller')
      expect(staging).not_to be_nil
      expect(File.exist?(staging)).to be(false)
      expect(File.binread(File.join(@target, 'a-new'))).to eq('new')
      expect(File.binread(File.join(@target, 'z-conflict'))).to eq('local')
      expect(Dir.children(@target).sort).to eq(%w[a-new z-conflict])
    end
  end
end