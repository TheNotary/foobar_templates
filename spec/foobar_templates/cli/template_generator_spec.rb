require 'spec_helper'
require 'tmpdir'

RSpec.describe FoobarTemplates::CLI::TemplateGenerator do
  around do |example|
    Dir.mktmpdir('generator-regression') do |dir|
      @root = File.join(dir, 'template')
      @destination = File.join(dir, 'destination')
      FileUtils.mkdir_p([@root, @destination])
      File.write(File.join(@root, 'foobar.yml'), "prefix: service-\n")
      Dir.chdir(@destination) { example.run }
    end
  end

  before do
    allow(FoobarTemplates::TemplateManager).to receive(:get_template_src).and_return(@root)
    @domains = { 'repo_domain' => 'github.com' }
    @configurator = double('configurator', always_perform_git_init: false)
    allow(@configurator).to receive(:domain) { |key| @domains[key] }
    allow(@configurator).to receive(:set_domain) { |key, value| @domains[key] = value }
    allow(FoobarTemplates::Configurator).to receive(:new).and_return(@configurator)
    allow_any_instance_of(FoobarTemplates::Core::InterpolationContext).to receive(:`).with('git config user.name').and_return("Test\n")
    allow_any_instance_of(FoobarTemplates::Core::InterpolationContext).to receive(:`).with('git config user.email').and_return("test@example.com\n")
  end

  def generator
    described_class.new({ template: 'sample', test: true }, 'good-dog')
  end

  def write_file(relative, bytes, mode = 0644)
    absolute = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, bytes)
    File.chmod(mode, absolute)
  end

  it 'generates rendered names/text and opaque binaries with original modes and empty directories' do
    write_file('FooBar/foo-bar.sh', "#!/bin/sh\nfoo-bar >>> foo-bar\n", 0751)
    write_file('foo_bar.bin', "\x00foo-bar\xff".b, 0640)
    write_file('FOO_BAR.dat', "foo-bar\xff".b, 0600)
    FileUtils.mkdir_p(File.join(@root, 'empty'))
    instance = generator
    allow(instance).to receive(:inside_git_work_tree?).and_return(true)
    expect(instance).to receive(:`).with('git add .').and_return('')
    expect(instance).not_to receive(:`).with('git init')

    capture_stdout { instance.run }

    destination = File.join(@destination, 'good-dog')
    expect(File.binread(File.join(destination, 'GoodDog/good-dog.sh'))).to eq("#!/bin/sh\ngood-dog foo-bar\n")
    expect(File.binread(File.join(destination, 'good_dog.bin'))).to eq("\x00foo-bar\xff".b)
    expect(File.binread(File.join(destination, 'GOOD_DOG.dat'))).to eq("foo-bar\xff".b)
    { 'GoodDog/good-dog.sh' => 0751, 'good_dog.bin' => 0640, 'GOOD_DOG.dat' => 0600 }.each do |path, mode|
      expect(File.stat(File.join(destination, path)).mode & 0777).to eq(mode)
    end
    expect(File.directory?(File.join(destination, 'empty'))).to be(true)
    expect(File.exist?(File.join(destination, 'foobar.yml'))).to be(false)
  end

  it 'keeps private replacement and enumeration compatibility methods' do
    write_file('foo-bar/file', 'foo-bar')
    instance = generator
    expect(instance.send(:collect_non_ignored_paths, @root)).to contain_exactly('foobar.yml', 'foo-bar', 'foo-bar/file')
    expect(instance.send(:dynamically_generate_template_directories)).to eq('foo-bar' => 'good-dog')
    expect(instance.send(:dynamically_generate_templates_files)).to eq('foo-bar/file' => 'good-dog/file')
    expect(instance.send(:substitute_template_values, 'foo_bar')).to eq('good_dog')
    expect(instance.send(:build_filename_replacement_pairs)).to include(['FooBar', 'GoodDog'])
    expect(instance.send(:build_content_replacement_pairs)).to include(['FOO_AUTHOR', 'Test'])
    expect(instance.send(:safe_gsub_template_variables, '>>> foo-bar')).to eq('>>> good-dog')
    expect(instance.send(:binary_file?, File.join(@root, 'foo-bar/file'))).to be(false)
    expect(instance.config[:test]).to be(true)
  end

  it 'keeps legacy metadata domain scanning and blank repo prompt default persistence' do
    File.write(File.join(@root, 'foobar.yml'), "description: FOO_GIT_REPO_URL\n")
    @domains.clear
    allow($stdin).to receive(:gets).and_return("\n")
    instance = generator
    output = capture_stdout do
      expect(instance.send(:scan_template_for_required_domains)).to eq(['repo_domain'])
      expect(instance.config[:git_repo_domain]).to eq('github.com')
    end
    expect(output).to include('Enter repo-domain (default: github.com):')
    expect(@domains['repo_domain']).to eq('github.com')
  end

  it 'retains the generator warning rather than re-prompting for empty required input' do
    write_file('file', 'FOO_REGISTRY_DOMAIN')
    expect($stdin).to receive(:gets).once.and_return("\n")
    instance = generator
    output = capture_stdout { instance.config }
    expect(output).to include('Warning: No value provided')
    expect(@domains['registry_domain']).to eq('')
  end

  it 'keeps the no-files and existing-project guards' do
    instance = generator
    expect { instance.send(:dynamically_generate_templates_files) }
      .to raise_error(FoobarTemplates::CLIError, /no files were found/)
    FileUtils.mkdir_p(File.join(@destination, 'good-dog'))
    expect { instance.run }.to raise_error(FoobarTemplates::CLIError, /already exists/)
  end
end