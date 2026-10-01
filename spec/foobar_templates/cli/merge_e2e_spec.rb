require 'spec_helper'
require 'open3'
require 'pty'
require 'io/console'
require 'timeout'
require 'tmpdir'
require 'rbconfig'
require 'digest'

# Exercise the executable and real terminal adapter together, without replacing
# the catalog, picker, configuration, renderer, or filesystem implementation.
RSpec.describe 'merge end-to-end verification' do
  let(:project_root) { File.expand_path('../../..', __dir__) }

  around do |example|
    Dir.mktmpdir('foobar-merge-e2e-') do |sandbox|
      @sandbox = sandbox
      @home = File.join(sandbox, 'home')
      @target = File.join(sandbox, 'sample-app')
      @templates = File.join(@home, '.foobar/templates')
      FileUtils.mkdir_p([@templates, @target])
      @env = {
        'HOME' => @home, 'TERM' => 'xterm-256color',
        'GIT_CONFIG_GLOBAL' => File.join(@home, '.gitconfig'),
        'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_COUNT' => '2',
        'GIT_CONFIG_KEY_0' => 'user.name', 'GIT_CONFIG_VALUE_0' => 'E2E Tester',
        'GIT_CONFIG_KEY_1' => 'user.email', 'GIT_CONFIG_VALUE_1' => 'e2e@example.test',
        'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil,
        'GIT_CONFIG' => nil, 'GIT_CONFIG_PARAMETERS' => nil,
        'XDG_CONFIG_HOME' => File.join(@home, '.config'),
      }
      File.write(File.join(@home, '.foobar/config'), YAML.dump('default_template' => 'does-not-exist'))
      example.run
    end
  end

  def executable(*args)
    [RbConfig.ruby, '-I', File.join(project_root, 'lib'),
     File.join(project_root, 'bin/foobar_templates'), 'merge', *args]
  end

  def run_piped(*args, input: '')
    Timeout.timeout(15) do
      Open3.capture3(@env, *executable(*args), stdin_data: input, chdir: @target)
    end
  end

  def add_template(name, files, metadata = {})
    path = File.join(@templates, "template-#{name}")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'foobar.yml'), YAML.dump(
      { 'bootstrap_command' => 'touch BOOTSTRAP_MUST_NOT_RUN' }.merge(metadata)
    ))
    files.each do |relative, bytes|
      destination = File.join(path, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
    end
    path
  end

  def git_at(path, *args)
    out, err, result = Open3.capture3(@env, 'git', '-C', path, *args)
    raise "git #{args.inspect}: #{out}#{err}" unless result.success?
    out
  end

  # Ignore atime (reading files legitimately changes it), but include file bytes,
  # modes and mtimes, and directory membership/modes, including Git internals.
  def tree_snapshot(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).reject { |name| name == '.' }.sort.to_h do |relative|
      path = File.join(root, relative)
      stat = File.lstat(path)
      value = [stat.ftype, stat.mode]
      value += [stat.mtime, Digest::SHA256.file(path).hexdigest] if stat.file?
      value << File.readlink(path) if stat.symlink?
      [relative, value]
    end
  end

  # Wait for each displayed frame/prompt before sending the next input. Retain a
  # slave handle to compare real terminal settings before/after process exit.
  def run_terminal(*args, steps:, size: [24, 80])
    transcript = +''
    result = nil
    PTY.open do |master, slave|
      slave.winsize = size
      original_settings = IO.popen(['stty', '-g'], in: slave, &:read)
      pid = Process.spawn(@env, *executable(*args), in: slave, out: slave,
                          err: slave, chdir: @target)
      cursor = 0
      receive = lambda do
        if IO.select([master], nil, nil, 0.05)
          chunk = master.read_nonblock(16_384, exception: false)
          transcript << chunk if chunk.is_a?(String)
        end
      end
      begin
        Timeout.timeout(15) do
          steps.each do |marker, action|
            receive.call until transcript.index(marker, cursor)
            cursor = transcript.index(marker, cursor) + marker.length
            action.respond_to?(:call) ? action.call(master, slave) : master.write(action)
          end
          loop do
            receive.call
            waited = Process.wait2(pid, Process::WNOHANG)
            if waited
              result = waited.last
              pid = nil
              break
            end
          end
          loop do
            chunk = master.read_nonblock(16_384, exception: false)
            break unless chunk.is_a?(String)
            transcript << chunk
          end
        end
        restored_settings = IO.popen(['stty', '-g'], in: slave, &:read)
        expect(restored_settings).to eq(original_settings), 'terminal mode was not restored'
      rescue Timeout::Error
        raise "Timed out waiting for terminal interaction. Transcript: #{transcript.inspect}"
      ensure
        if pid
          Process.kill('KILL', pid) rescue Errno::ESRCH
          Process.wait(pid) rescue Errno::ECHILD
        end
      end
    end
    [transcript, result]
  end

  def expect_no_lifecycle_side_effects
    expect(File.exist?(File.join(@target, '.git'))).to be(false)
    expect(File.exist?(File.join(@target, 'BOOTSTRAP_MUST_NOT_RUN'))).to be(false)
    expect(File.exist?(File.join(@target, 'foobar.yml'))).to be(false)
  end

  it 'uses real fullscreen Space/arrows/Enter to merge two templates in display order, not marking order' do
    add_template('aaa-e2e', { 'alpha/foo-bar.txt' => "alpha foo-bar\n", 'shared' => "first foo-bar\n" }, 'category' => 'backend')
    add_template('aab-e2e', { 'beta.txt' => "beta FooBar\n", 'shared' => "second foo-bar\n" }, 'category' => 'frontend')
    add_template('addon', { 'unused' => 'not selected' }, 'category' => 'partial')
    before = tree_snapshot(@templates)
    transcript, result = run_terminal(steps: [
      ['Enter confirm', "\e[B\e[B"],
      ['Focus: aab-e2e', ' '],
      ['1 selected', "\e[A"],
      ['Focus: aaa-e2e', ' '],
      ['2 selected', "\r"],
      ['Overwrite shared?', "d\n"],
      ['Overwrite shared?', "y\n"],
    ])
    expect(result.exitstatus).to eq(0), transcript
    expect(transcript).to include('BACKEND', 'FRONTEND', 'MISC', 'PARTIAL')
    expect(transcript.index('PARTIAL')).to be < transcript.index('BACKEND')
    expect(transcript).to include('Focus: addon')
    expect(File.exist?(File.join(@target, 'unused'))).to be(false)
    expect(transcript).to include("\e[?1049h", "\e[?1049l", "\e[?25h")
    expect(transcript).to include('-first sample-app', '+second sample-app', 'Template: aab-e2e')
    expect(transcript).to include('3 created, 1 overwritten, 0 unchanged, 0 skipped')
    expect(File.read(File.join(@target, 'alpha/sample-app.txt'))).to eq("alpha sample-app\n")
    expect(File.read(File.join(@target, 'beta.txt'))).to eq("beta SampleApp\n")
    expect(File.read(File.join(@target, 'shared'))).to eq("second sample-app\n")
    expect(tree_snapshot(@templates)).to eq(before)
    expect_no_lifecycle_side_effects
  end

  it 'preserves focus and marks across resize and vertical arrows, then merges only the marked entry' do
    add_template('aaa-e2e', 'alpha' => 'first')
    add_template('aab-e2e', 'beta' => 'second')
    transcript, result = run_terminal(steps: [
      ['Enter confirm', ' '],
      ['1 selected', ->(_master, slave) { slave.winsize = [12, 25] }],
      ['Focus: aaa-e2e', "\e[B"],
      ['Focus: aab-e2e', "\e[A"],
      ['Focus: aaa-e2e', "\r"],
    ])
    expect(result.exitstatus).to eq(0), transcript
    expect(Dir.children(@target)).to eq(['alpha'])
  end

  it 'accepts the focused unmarked template and prompts/persists required configuration after leaving fullscreen' do
    add_template('aaa-e2e', 'domain' => "FOO_K8S_DOMAIN foo-bar\n")
    transcript, result = run_terminal(steps: [
      ['Enter confirm', "\r"],
      ['Enter k8s-domain:', "\n"],
      ['Enter k8s-domain:', "cluster.example.test\n"],
    ])
    expect(result.exitstatus).to eq(0), transcript
    expect(transcript).to include('A nonempty value is required')
    expect(transcript.index("\e[?1049l")).to be < transcript.index('Enter k8s-domain:')
    expect(File.read(File.join(@target, 'domain'))).to eq("cluster.example.test sample-app\n")
    expect(YAML.load_file(File.join(@home, '.foobar/config'))['k8s_domain']).to eq('cluster.example.test')
  end

  { 'q' => 'q', 'Escape' => "\e", 'Ctrl-C' => "\x03" }.each do |name, key|
    it "cancels fullscreen with #{name}, restores terminal state and writes nothing" do
      add_template('aaa-e2e', 'alpha' => 'first')
      before = tree_snapshot(@templates)
      transcript, result = run_terminal(steps: [['Enter confirm', key]])
      expect(result.exitstatus).to eq(1), transcript
      expect(transcript).to include('cancelled', "\e[?1049l", "\e[?25h")
      expect(Dir.children(@target)).to be_empty
      expect(tree_snapshot(@templates)).to eq(before)
    end
  end

  [[], ['-a'], ['--merge-all-files-from-template'], ['-s', './src/foo-bar.txt']].each do |scope|
    it "merges explicit #{scope.inspect} in a non-TTY subprocess without lifecycle or source side effects" do
      source = add_template('aaa-e2e', 'src/foo-bar.txt' => "foo-bar FOO_AUTHOR\n", '.hidden' => 'dot',
                            'ignored' => 'excluded', '.gitignore' => "ignored\n")
      FileUtils.mkdir_p(File.join(source, 'empty'))
      File.chmod(0o751, File.join(source, 'src/foo-bar.txt'))
      git_at(source, 'init', '-q')
      before = tree_snapshot(@templates)
      stdout, stderr, result = run_piped('-t', 'aaa-e2e', *scope)
      expect(result.exitstatus).to eq(0), stderr
      expect(stderr).to be_empty
      expect(stdout).not_to include('Overwrite', 'Enter ', "\e")
      expect(File.read(File.join(@target, 'src/sample-app.txt'))).to eq("sample-app E2E Tester\n")
      expect(File.stat(File.join(@target, 'src/sample-app.txt')).mode & 0o777).to eq(0o751)
      expect(File.exist?(File.join(@target, 'ignored'))).to be(false)
      expect(File.directory?(File.join(@target, 'empty'))).to eq(!scope.include?('-s'))
      expect(File.exist?(File.join(@target, '.hidden'))).to eq(!scope.include?('-s'))
      expect(tree_snapshot(@templates)).to eq(before)
      expect_no_lifecycle_side_effects
    end
  end

  %w[n y].each do |decision|
    it "shows a rendered diff then #{decision}, without modifying source or existing target Git index" do
      source = add_template('aaa-e2e', 'foo-bar.txt' => "incoming foo-bar\n")
      destination = File.join(@target, 'sample-app.txt')
      File.write(destination, "local\n")
      git_at(@target, 'init', '-q')
      git_at(@target, 'add', '.')
      index = File.binread(File.join(@target, '.git/index'))
      before = tree_snapshot(source)
      transcript, result = run_terminal('-t', 'aaa-e2e', '-a', steps: [
        ['Overwrite sample-app.txt?', "d\n"],
        ['Overwrite sample-app.txt?', "#{decision}\n"],
      ])
      expect(result.exitstatus).to eq(0), transcript
      expect(transcript).to include('--- local/sample-app.txt', '+++ rendered/aaa-e2e/sample-app.txt',
                                    '-local', '+incoming sample-app')
      expect(File.read(destination)).to eq(decision == 'y' ? "incoming sample-app\n" : "local\n")
      expect(File.binread(File.join(@target, '.git/index'))).to eq(index)
      expect(tree_snapshot(source)).to eq(before)
      expect(File.exist?(File.join(@target, 'BOOTSTRAP_MUST_NOT_RUN'))).to be(false)
    end
  end

  it 'fails redirected conflicts atomically even when y is piped and -a is supplied' do
    add_template('aaa-e2e', 'a-new' => 'new', 'z-existing' => 'incoming')
    File.write(File.join(@target, 'z-existing'), 'local')
    before = tree_snapshot(@target)
    stdout, stderr, result = run_piped('-t', 'aaa-e2e', '-a', input: "y\n")
    expect(result.exitstatus).to eq(2), stderr
    expect(stderr).to include('No destination files were written')
    expect(stdout).not_to include('Overwrite', 'Merge complete')
    expect(tree_snapshot(@target)).to eq(before)
  end
end