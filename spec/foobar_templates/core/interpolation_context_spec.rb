require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'foobar_templates/core/interpolation_context'

RSpec.describe FoobarTemplates::Core::InterpolationContext do
  let(:domains) { {} }
  let(:configurator) do
    double('configurator').tap do |object|
      allow(object).to receive(:domain) { |key| domains[key] }
      allow(object).to receive(:set_domain) { |key, value| domains[key] = value }
    end
  end
  let(:input) { StringIO.new }
  let(:output) { StringIO.new }

  around do |example|
    Dir.mktmpdir('interpolation-context') do |dir|
      @root = dir
      example.run
    end
  end

  def context(name: 'good-dog', source_files: [], **options)
    described_class.new(
      name: name, template_root: @root, template_name: 'sample',
      source_files: source_files, configurator: configurator,
      input: input, output: output, **options
    ).tap do |object|
      allow(object).to receive(:`).with('git config user.name').and_return("Test\n")
      allow(object).to receive(:`).with('git config user.email').and_return("test@example.com\n")
    end
  end

  def write_file(path, content)
    absolute = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content)
  end

  it 'builds the generator name variants and composite values without its lifecycle' do
    object = context(name: 'tool-go-good-dog')
    expect(object.config).to include(
      name: 'tool-go-good-dog', title: 'Tool Go Good Dog', unprefixed_name: 'good-dog',
      unprefixed_pascal: 'GoodDog', pascal_name: 'ToolGoGoodDog', camel_name: 'toolGoGoodDog',
      underscored_name: 'tool_go_good_dog', screamcase_name: 'TOOL_GO_GOOD_DOG',
      namespaced_path: 'tool/go/good/dog', constant_name: 'Tool::Go::Good::Dog',
      constant_array: %w[Tool Go Good Dog], makefile_path: 'tool_go_good_dog/tool_go_good_dog',
      author: 'Test', email: 'test@example.com', git_repo_domain: 'github.com',
      git_repo_url: 'https://github.com/Test/tool-go-good-dog',
      git_repo_path: 'github.com/test/tool-go-good-dog', image_path: 'test/tool-go-good-dog',
      registry_repo_path: '/test/tool-go-good-dog', template: 'sample', test: nil
    )
    expect(object.config).to equal(object.config)
    expect(Dir.children(@root)).to be_empty
  end

  it 'uses explicit metadata prefix without changing the supplied name' do
    write_file('foobar.yml', "prefix: service-\n")
    expect(context(name: 'service-good-dog').config).to include(name: 'service-good-dog', unprefixed_name: 'good-dog')
  end

  it 'accepts empty metadata and derives prefixes from purpose and language' do
    write_file('foobar.yml', '')
    expect(context.config[:unprefixed_name]).to eq('good-dog')
    write_file('foobar.yml', "purpose: app\nlanguage: ruby\n")
    expect(context(name: 'app-ruby-good-dog').config[:unprefixed_name]).to eq('good-dog')
  end

  it 'scans only selected template-relative files, not metadata, paths, or unselected files' do
    write_file('foobar.yml', "description: FOO_K8S_DOMAIN\n")
    write_file('unselected', 'FOO_REGISTRY_DOMAIN')
    write_file('FOO_K8S_DOMAIN/selected', 'foo-bar')
    expect(input).not_to receive(:gets)
    expect(context(source_files: ['FOO_K8S_DOMAIN/selected']).config[:name]).to eq('good-dog')
    expect(output.string).to be_empty
  end

  it 'skips binary and invalid-encoding content when determining required domains' do
    write_file('binary', "FOO_REGISTRY_DOMAIN\x00")
    write_file('invalid', "FOO_K8S_DOMAIN\xff".b)
    expect(context(source_files: %w[binary invalid]).config[:name]).to eq('good-dog')
  end

  it 'does not require configuration for escaped tokens or late-NUL binary files' do
    write_file('escaped', ">>> FOO_K8S_DOMAIN\n>>> FOO_REGISTRY_DOMAIN")
    write_file('binary', ('foo-bar ' * 2000) + "\0FOO_K8S_DOMAIN")
    expect(input).not_to receive(:gets)
    expect(context(source_files: %w[escaped binary]).config[:name]).to eq('good-dog')
  end

  it 'still requires configuration for unescaped occurrences alongside escaped ones' do
    write_file('selected', '>>> FOO_K8S_DOMAIN FOO_K8S_DOMAIN')
    expect { context(source_files: ['selected']).config }
      .to raise_error(FoobarTemplates::CLIError, /k8s_domain/)
  end

  [nil, '', '   '].each do |value|
    it "uses github.com without prompting or persisting when repo_domain is #{value.inspect}" do
      domains['repo_domain'] = value
      write_file('selected', 'FOO_GIT_REPO_URL')
      expect(input).not_to receive(:gets)
      expect(configurator).not_to receive(:set_domain)
      expect(context(source_files: ['selected']).config[:git_repo_domain]).to eq('github.com')
      expect(context(source_files: ['selected'], interactive: true).config[:git_repo_domain]).to eq('github.com')
      expect(output.string).to be_empty
    end
  end

  it 'fails noninteractive preflight with all missing domains and no prompts or writes' do
    write_file('selected', 'FOO_REGISTRY_REPO_PATH FOO_K8S_DOMAIN')
    expect(input).not_to receive(:gets)
    expect(configurator).not_to receive(:set_domain)
    expect { context(source_files: ['selected']).validate! }
      .to raise_error(FoobarTemplates::CLIError, /registry_domain, k8s_domain/)
    expect(Dir.children(@root)).to eq(['selected'])
  end

  it 'uses configured domains without prompting' do
    domains.merge!('repo_domain' => 'git.example', 'registry_domain' => 'Registry.EXAMPLE', 'k8s_domain' => 'cluster.example')
    write_file('selected', 'FOO_GIT_REPO_PATH FOO_REGISTRY_DOMAIN FOO_K8S_DOMAIN')
    expect(input).not_to receive(:gets)
    expect(context(source_files: ['selected']).config).to include(
      git_repo_domain: 'git.example', registry_domain: 'Registry.EXAMPLE',
      registry_repo_path: 'registry.example/test/good-dog', k8s_domain: 'cluster.example'
    )
  end

  it 're-prompts for blank interactive answers and persists only a nonempty trimmed value' do
    write_file('selected', 'FOO_REGISTRY_DOMAIN')
    input.string = "\n   \n registry.example \n"
    object = context(source_files: ['selected'], interactive: true)
    expect(object.config[:registry_domain]).to eq('registry.example')
    expect(configurator).to have_received(:set_domain).with('registry_domain', 'registry.example').once
    expect(output.string.scan('Enter registry-domain:').length).to eq(3)
    expect(object.validate!).to equal(object)
  end

  it 'fails interactive EOF rather than saving an empty value' do
    write_file('selected', 'FOO_K8S_DOMAIN')
    expect(configurator).not_to receive(:set_domain)
    expect { context(source_files: ['selected'], interactive: true).config }
      .to raise_error(FoobarTemplates::CLIError, /end of input/)
  end

  it 'retains the legacy repo prompt and blank-input default' do
    write_file('selected', 'FOO_GIT_REPO_URL')
    input.string = "\n"
    expect(context(source_files: ['selected'], interactive: true, legacy: true).config[:git_repo_domain]).to eq('github.com')
    expect(domains['repo_domain']).to eq('github.com')
    expect(output.string).to include('Enter repo-domain (default: github.com):')
  end

  it 'retains the legacy warning and persistence of empty required domains' do
    write_file('selected', 'FOO_K8S_DOMAIN')
    context(source_files: ['selected'], interactive: true, legacy: true).config
    expect(domains['k8s_domain']).to eq('')
    expect(output.string).to include('Warning: No value provided')
  end

  it 'keeps the actionable missing git identity error and optional email fallback' do
    object = context
    allow(object).to receive(:`).with('git config user.name').and_return('')
    expect { object.config }.to raise_error(FoobarTemplates::CLIError, /git config --global user.name YOUR_GH_NAME/)
    object = context
    allow(object).to receive(:`).with('git config user.email').and_return('')
    expect(object.config[:email]).to eq('TODO: Write your email address')
  end

  it 'rejects the existing unsafe leading-number rule' do
    expect { context(name: '123-project').validate! }.to raise_error(FoobarTemplates::CLIError, /does not start with numbers/)
  end

  it 'checks declarative reserved names' do
    write_file('foobar.yml', "name_validation:\n  reserved_names: [good-dog]\n")
    expect { context.validate! }.to raise_error(FoobarTemplates::CLIError, /reserved by template 'sample'/)
  end

  it 'checks declarative regular expressions' do
    write_file('foobar.yml', "name_validation:\n  regex_validator: '^[a-z_]+$'\n")
    expect { context.validate! }.to raise_error(FoobarTemplates::CLIError, /does not match/)
    expect { context(name: 'good_dog').validate! }.not_to raise_error
  end

  it 'reports malformed declarative regular expressions' do
    write_file('foobar.yml', "name_validation:\n  regex_validator: '[unclosed'\n")
    expect { context.validate! }.to raise_error(FoobarTemplates::CLIError, /invalid name_validation.regex_validator/)
  end

  it 'validates an inferred name even when the project directory already exists' do
    FileUtils.mkdir_p(File.join(@root, 'good-dog'))
    Dir.chdir(@root) { expect { context.validate! }.not_to raise_error }
  end
end