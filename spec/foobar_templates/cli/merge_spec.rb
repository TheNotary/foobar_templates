require 'spec_helper'
require 'stringio'

RSpec.describe FoobarTemplates::CLI::Merge do
  let(:input) { StringIO.new }
  let(:output) { StringIO.new }
  let(:error) { StringIO.new }
  let(:counts) { { created: 1, overwritten: 2, unchanged: 3, skipped: 4 } }
  let(:entry) { { name: 'api', label: 'api (custom/api)', path: '/templates/api' } }

  def run_command(*argv)
    described_class.run(argv, input: input, output: output, error: error)
  end

  describe 'argument validation and help' do
    before do
      expect(FoobarTemplates::Configurator).not_to receive(:new)
      expect(FoobarTemplates::TemplateManager).not_to receive(:get_template_src)
      expect(FoobarTemplates::CLI::TemplatePicker).not_to receive(:new)
    end

    %w[-h --help].each do |flag|
      it "prints #{flag} without setup" do
        expect(run_command(flag)).to eq(0)
        expect(output.string).to include('Usage: foobar_templates merge', '--select PATH', 'NOT force', 'Exit status:')
        expect(error.string).to be_empty
      end
    end

    [
      ['-s', 'file', '-a'], ['--select=file', '--merge-all-files-from-template'],
      ['-t', 'api', '--template', 'other'], ['-s', 'file', '--select=file'],
      ['-t'], ['-s'], ['--template='], ['--select='], ['-t', ' '], ['-s', ' '],
      ['-t', '/tmp/api'], ['-t', '../api'], ['-t', 'repo/api'], ['-t', '..'],
      ['-t', 'C:\\api'], ['-s', '/file'], ['-s', '../file'], ['-s', 'a/../file'],
      ['-s', './a/../../file'], ['-s', 'C:/file'], ['-s', '\\file'], ['-s', 'a\\..\\file'],
      ['-s', '.'], ['-s', './'], ['-s', 'dir/'], ['-t', "bad\e[2J"], ['-s', "file\nname"],
      ['--unknown'], ['extra'], ['--', 'extra'], ['-t', '-a'], ['-s', '-h'],
    ].each do |argv|
      it "rejects #{argv.inspect} before setup" do
        expect(run_command(*argv)).to eq(1)
        expect(error.string).not_to be_empty
        expect(error.string).not_to include("\e")
        expect(output.string).to be_empty
      end
    end
  end

  describe 'command boundary' do
    let(:engine_class) { Class.new { def run(interactive:); end } }
    let(:engine) { engine_class.new }
    let(:configurator) { instance_double(FoobarTemplates::Configurator) }

    before do
      stub_const('FoobarTemplates::Core::Merger', engine_class)
      stub_const('FoobarTemplates::Core::Merger::ConflictError', Class.new(FoobarTemplates::CLIError))
      allow(FoobarTemplates::Configurator).to receive(:new).and_return(configurator)
      allow(FoobarTemplates::TemplateManager).to receive(:get_template_src).with(template: 'api').and_return(entry[:path])
      allow(engine_class).to receive(:new).and_return(engine)
      allow(engine).to receive(:run).and_return(counts)
    end

    [[], ['-a'], ['--merge-all-files-from-template']].each do |scope|
      it "uses all files for #{scope.inspect} without reads on redirected streams" do
        expect(input).not_to receive(:gets)
        expect(FoobarTemplates::CLI::TemplatePicker).not_to receive(:new)
        expect(engine_class).to receive(:new).with(
          target: Dir.pwd, templates: [{ name: 'api', label: 'api', path: entry[:path] }],
          selected_file: nil, configurator: configurator, interactive_config: false,
          input: input, output: output
        ).and_return(engine)
        expect(engine).to receive(:run).with(interactive: false).and_return(counts)
        expect(run_command('-t', 'api', *scope)).to eq(0)
        expect(output.string).to include('1 created, 2 overwritten, 3 unchanged, 4 skipped')
      end
    end

    it 'normalizes a leading ./ source selection without rendering it in the CLI' do
      expect(engine_class).to receive(:new).with(hash_including(selected_file: 'src/foo-bar.rb')).and_return(engine)
      expect(run_command('--template=api', '--select=./src/foo-bar.rb')).to eq(0)
    end

    it 'passes picker identities and selection order unchanged, never resolving a default' do
      second = { name: 'other', label: 'other', path: '/templates/other' }
      picker = instance_double(FoobarTemplates::CLI::TemplatePicker)
      allow(input).to receive(:tty?).and_return(true)
      allow(output).to receive(:tty?).and_return(true)
      expect(FoobarTemplates::TemplateManager).to receive(:available_templates).and_return([entry, second])
      expect(FoobarTemplates::TemplateManager).not_to receive(:get_template_src)
      expect(FoobarTemplates::CLI::TemplatePicker).to receive(:new).with(
        [entry, second], hash_including(input: input, output: output, file_lister: kind_of(Proc), file_merger: kind_of(Proc))
      ).and_return(picker)
      expect(picker).to receive(:choose).and_return([entry, second])
      expect(engine_class).to receive(:new).with(hash_including(templates: [entry, second], interactive_config: true)).and_return(engine)
      expect(engine).to receive(:run).with(interactive: true).and_return(counts)
      expect(run_command).to eq(0)
    end

    it 'never enables configuration prompts for explicit templates even on a TTY' do
      allow(input).to receive(:tty?).and_return(true)
      allow(output).to receive(:tty?).and_return(true)
      expect(engine_class).to receive(:new).with(hash_including(interactive_config: false)).and_return(engine)
      expect(run_command('-t', 'api')).to eq(0)
    end

    [[true, false], [false, true]].each do |input_tty, output_tty|
      it "disables conflict interaction when input tty=#{input_tty} and output tty=#{output_tty}" do
        allow(input).to receive(:tty?).and_return(input_tty)
        allow(output).to receive(:tty?).and_return(output_tty)
        expect(engine).to receive(:run).with(interactive: false).and_return(counts)
        expect(run_command('-t', 'api')).to eq(0)
      end
    end

    it 'passes conflict decisions from the prompt back to the engine' do
      allow(input).to receive(:tty?).and_return(true)
      allow(output).to receive(:tty?).and_return(true)
      input.write("n\n"); input.rewind
      candidate = Struct.new(:relative_path, :template, :bytes).new('app.rb', entry, 'new')
      expect(engine).to receive(:run).with(interactive: true) do |&decision|
        expect(decision.call(candidate, 'local')).to be(false)
        counts
      end
      expect(run_command('-t', 'api')).to eq(0)
      expect(output.string).to include('Overwrite app.rb?')
    end

    it 'returns status 2 for the engine non-TTY preflight conflict' do
      allow(engine).to receive(:run).and_raise(engine_class::ConflictError, 'Conflicting files: app.rb')
      expect(run_command('-t', 'api')).to eq(2)
      expect(error.string).to include('Conflicting files')
      expect(output.string).not_to include('Merge complete')
    end

    it 'sanitizes IO/configuration errors without a backtrace' do
      allow(engine).to receive(:run).and_raise(Errno::EACCES, "unsafe\e[2J\rfile")
      expect(run_command('-t', 'api')).to eq(1)
      expect(error.string).to include('Permission denied', '\\u001B[2J\\u000Dfile')
      expect(error.string).not_to include("\e", "\r", '.rb:')
    end

    it 'unwinds the picker before handling Interrupt' do
      restored = false
      picker = instance_double(FoobarTemplates::CLI::TemplatePicker)
      allow(FoobarTemplates::TemplateManager).to receive(:available_templates).and_return([entry])
      allow(FoobarTemplates::CLI::TemplatePicker).to receive(:new).and_return(picker)
      allow(picker).to receive(:choose) do
        begin
          raise Interrupt
        ensure
          restored = true
        end
      end
      expect(engine_class).not_to receive(:new)
      expect(run_command).to eq(1)
      expect(restored).to be(true)
      expect(error.string).to include('cancelled', 'no rollback')
    end

    it 'delegates from the public entrypoint and returns its status' do
      expect(described_class).to receive(:run).with(['--help'], input: input, output: output, error: error).and_return(0)
      expect(FoobarTemplates.merge(['--help'], input: input, output: output, error: error)).to eq(0)
    end

    describe 'picker file tree' do
      let(:picker) { instance_double(FoobarTemplates::CLI::TemplatePicker) }

      before do
        allow(input).to receive(:tty?).and_return(true)
        allow(output).to receive(:tty?).and_return(true)
        allow(FoobarTemplates::TemplateManager).to receive(:available_templates).and_return([entry])
        allow(FoobarTemplates::CLI::TemplatePicker).to receive(:new) do |_entries, **options|
          @tree_options = options
          picker
        end
      end

      def leave_picker_after
        allow(picker).to receive(:choose) do
          yield @tree_options
          raise FoobarTemplates::CLI::TemplatePicker::Cancelled, 'Template selection cancelled.'
        end
      end

      it 'merges one source file immediately and exits cleanly when the picker is left' do
        input.write("\n"); input.rewind
        expect(engine_class).to receive(:new).with(hash_including(
          templates: [entry], selected_file: 'src/foo-bar.rb', interactive_config: true
        )).and_return(engine)
        expect(engine).to receive(:run).with(interactive: true)
          .and_return(created: 1, overwritten: 0, unchanged: 0, skipped: 0)
        leave_picker_after do |options|
          expect(options[:file_merger].call(entry, 'src/foo-bar.rb')).to eq(:created)
        end
        expect(run_command).to eq(0)
        expect(output.string).to include('Merging src/foo-bar.rb from api (custom/api)', 'src/foo-bar.rb: created',
                                         'Press Enter to return', '1 created, 0 overwritten, 0 unchanged, 0 skipped')
      end

      it 'reports a failed file as an error and still treats leaving without merges as cancellation' do
        input.write("\n"); input.rewind
        allow(engine).to receive(:run).and_raise(FoobarTemplates::CLIError, "boom\e[2J")
        leave_picker_after do |options|
          expect(options[:file_merger].call(entry, 'file')).to eq(:error)
        end
        expect(run_command).to eq(1)
        expect(output.string).to include('boom\\u001B[2J', 'Press Enter to return')
        expect(output.string).not_to include('Merge complete')
        expect(error.string).to include('cancelled')
      end

      it 'lists strict template source files and rejects monorepo containers' do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, 'src'))
          File.write(File.join(root, 'src/a.rb'), 'a')
          File.write(File.join(root, 'foobar.yml'), 'category: misc')
          leave_picker_after do |options|
            expect(options[:file_lister].call(entry.merge(path: root))).to eq(['src/a.rb'])
            allow(FoobarTemplates::TemplateManager).to receive(:monorepo_directory?).and_return(true)
            expect { options[:file_lister].call(entry.merge(path: root)) }
              .to raise_error(FoobarTemplates::CLIError, /monorepo container/)
          end
          expect(run_command).to eq(1)
        end
      end

      it 'lists gitignored template entries as non-mergeable hashes' do
        Dir.mktmpdir do |root|
          system('git', '-C', root, 'init', '-q', exception: true)
          FileUtils.mkdir_p(File.join(root, 'vendor/pkg'))
          File.write(File.join(root, 'vendor/pkg/x'), 'x')
          File.write(File.join(root, '.gitignore'), "vendor/\nsecret.env\n")
          File.write(File.join(root, 'secret.env'), 's')
          leave_picker_after do |options|
            expect(options[:file_lister].call(entry.merge(path: root))).to contain_exactly(
              '.gitignore',
              { path: 'secret.env', ignored: true, directory: false },
              { path: 'vendor', ignored: true, directory: true }
            )
          end
          expect(run_command).to eq(1)
        end
      end
    end
  end

  describe 'overwrite decisions and diffs' do
    let(:candidate) { Struct.new(:relative_path, :template, :bytes).new('my-app.rb', entry, "new my-app\n") }
    let(:prompt) { described_class.new(input: input, output: output, color: false) }

    before do
      allow(input).to receive(:tty?).and_return(true)
      allow(output).to receive(:tty?).and_return(true)
    end

    def answer_with(text)
      input.write(text)
      input.rewind
      prompt.confirm(candidate, "old local\n")
    end

    it 'shows the diff before asking the exact question and accepts uppercase y' do
      expect(answer_with("Y\n")).to be(true)
      expect(output.string).to start_with("--- local/my-app.rb\n+++ rendered/api (custom/api)/my-app.rb\n@@")
      expect(output.string).to end_with("Overwrite my-app.rb? [y/n; choose d to show diff or e to edit]\n")
      expect(output.string.scan('--- local/').length).to eq(1)
    end

    it 're-prompts for blank/invalid answers and accepts uppercase n' do
      expect(answer_with("\nno\nwhat\nN\n")).to be(false)
      expect(output.string.scan('Overwrite my-app.rb?').length).to eq(4)
    end

    it 'shows rendered unified diffs repeatedly without deciding until y/n' do
      expect(answer_with("d\nD\nn\n")).to be(false)
      expect(output.string).to include('--- local/my-app.rb', '+++ rendered/api (custom/api)/my-app.rb', '@@', '-old local', '+new my-app')
      expect(output.string.scan('Overwrite my-app.rb?').length).to eq(3)
    end

    it 'merges overlapping diff hunks and retains separate distant hunks' do
      local = (1..25).map { |i| "line #{i}\n" }.join
      candidate.bytes = local.sub('line 2', 'changed 2').sub('line 4', 'changed 4').sub('line 23', 'changed 23')
      input.write("y\n"); input.rewind
      expect(prompt.confirm(candidate, local)).to be(true)
      expect(output.string.scan(/^@@ /).length).to eq(2)
      expect(output.string).to include('+changed 2', '+changed 4', '+changed 23')
    end

    ["data\0secret".b, "bad\xFFsecret".b].each do |bytes|
      it "does not display binary/invalid UTF-8 bytes #{bytes.inspect}" do
        candidate.bytes = bytes
        expect(answer_with("d\nn\n")).to be(false)
        expect(output.string).to include('Binary or invalid UTF-8 files differ')
        expect(output.string).not_to include('secret', "\0", '--- local/')
      end
    end

    it 'checks the local side for binary data too' do
      input.write("d\ny\n"); input.rewind
      expect(prompt.confirm(candidate, "local\0secret")).to be(true)
      expect(output.string).to include('Binary or invalid UTF-8 files differ')
      expect(output.string).not_to include('secret')
    end

    it 'escapes controls in paths, template labels and text while keeping Unicode readable' do
      candidate.relative_path = "evil\e[2J\n.rb"
      candidate.template = entry.merge(label: "api\r\u202E")
      candidate.bytes = "café\e[2J\x07\u009B\u202E\n"
      prompt = described_class.new(input: input, output: output, multiple_templates: true, color: false)
      input.write("d\nn\n"); input.rewind
      expect(prompt.confirm(candidate, "local\r\n")).to be(false)
      expect(output.string).to include('Template: api\\u000D\\u202E', 'evil\\u001B[2J\\u000A.rb', 'café\\u001B[2J\\u0007\\u009B\\u202E', '-local\\u000D')
      expect(output.string).not_to match(/[\e\r\x07\u009B\u202E]/)
    end

    it 'shows newline-only changes and no-newline markers' do
      candidate.bytes = 'same'
      input.write("d\nn\n"); input.rewind
      expect(prompt.confirm(candidate, "same\n")).to be(false)
      expect(output.string).to include('-same', '+same', '\\ No newline at end of file')
    end

    it 'cancels safely on EOF' do
      expect { answer_with('') }.to raise_error(FoobarTemplates::CLIError, /end of input.*no rollback/)
    end

    it 'propagates Interrupt to the command boundary' do
      allow(input).to receive(:gets).and_raise(Interrupt)
      expect { prompt.confirm(candidate, 'local') }.to raise_error(Interrupt)
    end

    describe 'colors' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('TERM').and_return('xterm')
      end

      it 'colors only its own diff markup on a terminal' do
        allow(ENV).to receive(:[]).with('NO_COLOR').and_return(nil)
        candidate.bytes = "new \e[2J\n"
        input.write("n\n"); input.rewind
        described_class.new(input: input, output: output).confirm(candidate, "old local\n")
        expect(output.string).to include("\e[1m--- local/my-app.rb\e[0m", "\e[36m@@ -1 +1 @@\e[0m",
                                         "\e[31m-old local\e[0m", "\e[32m+new \\u001B[2J\e[0m")
        expect(output.string).not_to include("\e[2J")
      end

      it 'honors NO_COLOR and non-terminal output' do
        allow(ENV).to receive(:[]).with('NO_COLOR').and_return('1')
        input.write("n\n"); input.rewind
        described_class.new(input: input, output: output).confirm(candidate, "old local\n")
        expect(output.string).to include('-old local')
        expect(output.string).not_to include("\e")
        allow(output).to receive(:tty?).and_return(false)
        allow(ENV).to receive(:[]).with('NO_COLOR').and_return(nil)
        expect(described_class.color?(output)).to be(false)
      end
    end

    describe 'editing conflicts' do
      let(:edits) { [] }

      def editor_prompt(&edit)
        described_class.new(input: input, output: output, color: false, editor: lambda do |path|
          edits << [path, File.read(path), File.stat(path).mode & 0o777]
          edit.call(path)
        end)
      end

      it 'opens a private Git-style buffer and returns the saved resolution' do
        input.write("e\n"); input.rewind
        prompt = editor_prompt { |path| File.write(path, "resolved\n") }
        expect(prompt.confirm(candidate, "old local\n")).to eq("resolved\n".b)
        path, buffer, mode = edits.first
        expect(path).to start_with('/')
        expect(File.basename(path)).to eq('my-app.rb')
        expect(mode).to eq(0o600)
        expect(buffer).to eq("<<<<<<< local/my-app.rb\nold local\n=======\nnew my-app\n" \
                             ">>>>>>> rendered/api (custom/api)/my-app.rb\n")
        expect(File.exist?(path)).to be(false)
        expect(output.string).to include('Saving resolved my-app.rb.')
      end

      it 'never saves remaining markers and resumes the edited buffer on the next e' do
        input.write("e\ne\n"); input.rewind
        prompt = editor_prompt do |path|
          File.write(path, edits.length == 1 ? "#{File.read(path)}note\n" : "done\n")
        end
        expect(prompt.confirm(candidate, "old local\n")).to eq('done' + "\n")
        expect(edits[1][1]).to start_with('<<<<<<< local/my-app.rb').and end_with("note\n")
        expect(output.string).to include('Conflict markers remain in my-app.rb; nothing was saved.')
      end

      it 'saves nothing when the editor fails and keeps prompting' do
        input.write("e\nn\n"); input.rewind
        prompt = editor_prompt { |path| File.write(path, "partial\n") && false }
        expect(prompt.confirm(candidate, "old local\n")).to be(false)
        expect(output.string).to include('Editor did not exit successfully')
      end

      it 'refuses to edit binary content' do
        candidate.bytes = "bin\0".b
        input.write("e\nn\n"); input.rewind
        prompt = editor_prompt { raise 'editor must not run' }
        expect(prompt.confirm(candidate, "old\n")).to be(false)
        expect(output.string).to include('cannot be edited')
      end

      it 'runs VISUAL before EDITOR as an argv without a shell, defaulting to vi' do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('VISUAL').and_return("code --wait '--new window'")
        allow(ENV).to receive(:[]).with('EDITOR').and_return('nano')
        prompt = described_class.new(input: input, output: output, color: false)
        expect(prompt).to receive(:system).with('code', '--wait', '--new window', '/tmp/x; rm -rf ~').and_return(true)
        expect(prompt.send(:launch_editor, '/tmp/x; rm -rf ~')).to be(true)

        allow(ENV).to receive(:[]).with('VISUAL').and_return(' ')
        allow(ENV).to receive(:[]).with('EDITOR').and_return(nil)
        expect(prompt).to receive(:system).with('vi', '/tmp/y').and_return(nil)
        expect(prompt.send(:launch_editor, '/tmp/y')).to be(false)

        allow(ENV).to receive(:[]).with('VISUAL').and_return("bad 'quote")
        expect(prompt.send(:launch_editor, '/tmp/z')).to be(false)
        expect(output.string).to include('Cannot parse editor command')
      end
    end
  end
end