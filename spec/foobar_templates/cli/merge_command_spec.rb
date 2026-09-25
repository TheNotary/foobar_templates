require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'pty'
require 'timeout'

RSpec.describe 'foobar_templates merge executable' do
  let(:root) { File.expand_path('../../..', __dir__) }

  around do |example|
    Dir.mktmpdir('foobar-merge-command-') do |sandbox|
      @home = File.join(sandbox, 'home')
      @target = File.join(sandbox, 'my-app')
      FileUtils.mkdir_p([@home, @target])
      @env = {
        'HOME' => @home, 'GIT_CONFIG_GLOBAL' => File.join(@home, '.gitconfig'),
        'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_COUNT' => '2',
        'GIT_CONFIG_KEY_0' => 'user.name', 'GIT_CONFIG_VALUE_0' => 'Merge Tester',
        'GIT_CONFIG_KEY_1' => 'user.email', 'GIT_CONFIG_VALUE_1' => 'merge@example.com',
      }
      example.run
    end
  end

  def command(*args, stdin: '')
    Open3.capture3(@env, RbConfig.ruby, '-I', File.join(root, 'lib'),
                  File.join(root, 'bin/foobar_templates'), *args, stdin_data: stdin, chdir: @target)
  end

  def template(files = {}, metadata: {})
    path = File.join(@home, '.foobar/templates/template-merge-fixture')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'foobar.yml'), YAML.dump(metadata))
    files.each do |name, bytes|
      destination = File.join(path, name)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
    end
    path
  end

  # A real canonical-mode terminal exercises tty? and actual executable dispatch.
  # Bound the whole exchange so prompt regressions fail rather than hang the suite.
  def terminal_command(*args, answers: [], interrupt: false)
    transcript = +''
    result = nil
    PTY.open do |master, slave|
      slave.echo = false
      pid = Process.spawn(@env, RbConfig.ruby, '-I', File.join(root, 'lib'),
                          File.join(root, 'bin/foobar_templates'), *args,
                          in: slave, out: slave, err: slave, chdir: @target)
      slave.close
      answered = 0
      begin
        Timeout.timeout(15) do
          begin
            loop do
              transcript << master.readpartial(4096)
              questions = transcript.scan('[y/n; choose d to show diff]').length
              while answered < questions
                if interrupt
                  Process.kill('INT', pid)
                elsif answered < answers.length
                  master.write(answers[answered])
                else
                  master.write("\x04") # canonical EOF, not a raw byte response
                end
                answered += 1
              end
            end
          rescue EOFError, Errno::EIO
            # Linux PTYs report EIO when their last slave closes.
          end
          _, result = Process.wait2(pid)
          pid = nil
        end
      ensure
        if pid
          begin
            Process.kill('KILL', pid)
          rescue Errno::ESRCH
          end
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
          end
        end
      end
    end
    [transcript, result]
  end

  %w[-h --help].each do |flag|
    it "dispatches merge #{flag} without initializing configuration" do
      stdout, stderr, result = command('merge', flag)
      expect(result.exitstatus).to eq(0), stderr
      expect(stdout).to include('Usage: foobar_templates merge', '--merge-all-files-from-template')
      expect(stderr).to be_empty
      expect(Dir.children(@home)).to be_empty
      expect(Dir.children(@target)).to be_empty
    end
  end

  it 'preserves legacy help and version dispatch' do
    stdout, stderr, result = command('--help')
    expect(result.exitstatus).to eq(0), stderr
    expect(stdout).to include('GEM_NAME', '--copy-to-templates', 'foobar_templates merge')
    stdout, stderr, result = command('--version')
    expect(result.exitstatus).to eq(0), stderr
    expect(stdout.strip).to eq(FoobarTemplates::VERSION)
  end

  [
    ['-s', 'file', '-a'], ['-t', 'one', '--template', 'two'], ['--template='],
    ['--select='], ['-s', '../file'], ['-t', '/tmp/template'], ['extra'], ['--wat'],
  ].each do |args|
    it "rejects #{args.inspect} before touching configuration or target" do
      stdout, stderr, result = command('merge', *args)
      expect(result.exitstatus).to eq(1)
      expect(stdout).to be_empty
      expect(stderr).not_to be_empty
      expect(stderr).not_to include('Traceback', '.rb:')
      expect(Dir.children(@home)).to be_empty
      expect(Dir.children(@target)).to be_empty
    end
  end

  context 'with the real merge engine' do
    %w[y n].each do |answer|
      it "shows a real-terminal rendered diff then applies #{answer} with the correct counts" do
        template({ 'foo-bar.rb' => "incoming foo-bar\n" })
        destination = File.join(@target, 'my-app.rb')
        File.write(destination, "local\n")
        transcript, result = terminal_command('merge', '-t', 'merge-fixture', '-a',
                                              answers: ["d\n", "#{answer.upcase}\n"])
        expect(result.exitstatus).to eq(0), transcript
        expect(transcript).to include('--- local/my-app.rb', '+++ rendered/merge-fixture/my-app.rb', '-local', '+incoming my-app')
        expect(transcript.scan('Overwrite my-app.rb?').length).to eq(2)
        expect(transcript).to include(answer == 'y' ? '1 overwritten' : '1 skipped')
        expect(File.read(destination)).to eq(answer == 'y' ? "incoming my-app\n" : "local\n")
      end
    end

    it 'shows a binary notice in a real terminal without emitting bytes' do
      template({ 'image' => "secret\0\xFF".b })
      File.binwrite(File.join(@target, 'image'), "local\0".b)
      transcript, result = terminal_command('merge', '-t', 'merge-fixture', answers: ["d\n", "n\n"])
      expect(result.exitstatus).to eq(0), transcript
      expect(transcript).to include('Binary or invalid UTF-8 files differ', '1 skipped')
      expect(transcript).not_to include('secret', "\0", "\xFF".b)
    end

    it 'returns 1 on terminal EOF and retains earlier completed writes without overwriting the conflict' do
      template({ 'a-created' => 'new', 'z-conflict' => 'incoming' })
      File.write(File.join(@target, 'z-conflict'), 'local')
      transcript, result = terminal_command('merge', '-t', 'merge-fixture')
      expect(result.exitstatus).to eq(1), transcript
      expect(transcript).to include('end of input', 'no rollback')
      expect(transcript).not_to include('Merge complete', '.rb:')
      expect(File.read(File.join(@target, 'a-created'))).to eq('new')
      expect(File.read(File.join(@target, 'z-conflict'))).to eq('local')
    end

    it 'handles actual SIGINT before the legacy trap, without a backtrace or rollback' do
      template({ 'a-created' => 'new', 'z-conflict' => 'incoming' })
      File.write(File.join(@target, 'z-conflict'), 'local')
      transcript, result = terminal_command('merge', '-t', 'merge-fixture', interrupt: true)
      expect(result.exitstatus).to eq(1), transcript
      expect(transcript).to include('Merge cancelled', 'no rollback')
      expect(transcript).not_to include('Merge complete', '.rb:')
      expect(File.read(File.join(@target, 'a-created'))).to eq('new')
      expect(File.read(File.join(@target, 'z-conflict'))).to eq('local')
    end

    [[], ['-a'], ['--merge-all-files-from-template']].each do |scope|
      it "renders all files for #{scope.inspect} with redirected streams and no bootstrap/Git side effects" do
        source = template({ 'foo-bar.rb' => "name=foo-bar\nFOO_AUTHOR\n", '.hidden' => 'keep' },
                          metadata: { 'bootstrap_command' => 'touch BOOTSTRAPPED' })
        File.chmod(0o755, File.join(source, 'foo-bar.rb'))
        FileUtils.mkdir_p(File.join(source, 'empty'))
        stdout, stderr, result = command('merge', '-t', 'merge-fixture', *scope)
        expect(result.exitstatus).to eq(0), stderr
        expect(stderr).to be_empty
        expect(stdout).to include('2 created', '0 overwritten')
        expect(stdout).not_to include('Overwrite', 'Enter ', "\e")
        expect(File.binread(File.join(@target, 'my-app.rb'))).to eq("name=my-app\nMerge Tester\n")
        expect(File.stat(File.join(@target, 'my-app.rb')).mode & 0o777).to eq(0o755)
        expect(File.directory?(File.join(@target, 'empty'))).to be(true)
        expect(File.read(File.join(@target, '.hidden'))).to eq('keep')
        %w[.git foobar.yml BOOTSTRAPPED].each { |name| expect(File.exist?(File.join(@target, name))).to be(false) }
        expect(File.read(File.join(source, 'foo-bar.rb'))).to include('foo-bar')
      end
    end

    it 'selects a source path before rendering and does not scan unrelated placeholders' do
      template({ 'src/foo-bar.rb' => 'foo-bar', 'unselected' => 'FOO_K8S_DOMAIN' })
      stdout, stderr, result = command('merge', '--template=merge-fixture', '--select=./src/foo-bar.rb')
      expect(result.exitstatus).to eq(0), stderr
      expect(stdout).to include('1 created')
      expect(File.read(File.join(@target, 'src/my-app.rb'))).to eq('my-app')
      expect(File.exist?(File.join(@target, 'unselected'))).to be(false)
    end

    it 'leaves identical rendered files and their mode/mtime untouched without prompting' do
      template({ 'foo-bar.rb' => "my-app\n" })
      destination = File.join(@target, 'my-app.rb')
      File.write(destination, "my-app\n")
      File.chmod(0o600, destination)
      File.utime(Time.at(1_000_000), Time.at(1_000_000), destination)
      before = File.stat(destination)
      stdout, stderr, result = command('merge', '-t', 'merge-fixture')
      expect(result.exitstatus).to eq(0), stderr
      expect(stdout).to include('1 unchanged')
      expect(stdout).not_to include('Overwrite')
      expect(File.stat(destination).mtime).to eq(before.mtime)
      expect(File.stat(destination).mode).to eq(before.mode)
    end

    it 'returns 2 before any writes for redirected conflicts even with -a and piped y' do
      template({ 'a-new' => 'new', 'z-conflict' => 'incoming' })
      File.write(File.join(@target, 'z-conflict'), 'local')
      stdout, stderr, result = command('merge', '-t', 'merge-fixture', '-a', stdin: "y\n")
      expect(result.exitstatus).to eq(2), stderr
      expect(stdout).not_to include('Merge complete', 'Overwrite')
      expect(stderr).not_to be_empty
      expect(Dir.children(@target)).to eq(['z-conflict'])
      expect(File.read(File.join(@target, 'z-conflict'))).to eq('local')
    end

    it 'fails missing required configuration without reading piped values or writing' do
      template({ 'a-new' => 'new', 'domain' => 'FOO_K8S_DOMAIN' })
      stdout, stderr, result = command('merge', '-t', 'merge-fixture', stdin: "example.com\n")
      expect(result.exitstatus).to eq(1)
      expect(stderr).to include('k8s_domain')
      expect(stdout).not_to include('Enter ')
      expect(Dir.children(@target)).to be_empty
    end

    it 'requires the picker rather than choosing the default with redirected input' do
      template({ 'file' => 'new' })
      stdout, stderr, result = command('merge')
      expect(result.exitstatus).to eq(1)
      expect(stderr).to include('terminal', '-t')
      expect(stdout).not_to include("\e", 'Merge complete')
      expect(Dir.children(@target)).to be_empty
    end

    it 'copies binary bytes without trying to render them' do
      bytes = "foo-bar\0\xFF\e".b
      template({ 'image.bin' => bytes })
      stdout, stderr, result = command('merge', '-t', 'merge-fixture')
      expect(result.exitstatus).to eq(0), stderr
      expect(stdout).to include('1 created')
      expect(File.binread(File.join(@target, 'image.bin'))).to eq(bytes)
    end

    it 'rejects missing selected files and monorepo containers without writes' do
      template({ 'file' => 'new' })
      _stdout, stderr, result = command('merge', '-t', 'merge-fixture', '-s', 'absent')
      expect(result.exitstatus).to eq(1)
      expect(stderr).to include('absent')
      expect(Dir.children(@target)).to be_empty
      template({}, metadata: { 'monorepo' => true })
      _stdout, stderr, result = command('merge', '-t', 'merge-fixture')
      expect(result.exitstatus).to eq(1)
      expect(stderr).to match(/monorepo|container/)
      expect(Dir.children(@target)).to be_empty
    end
  end
end