require 'spec_helper'
require 'tmpdir'

RSpec.describe FoobarTemplates::TemplateManager, '.available_templates' do
  around do |example|
    Dir.mktmpdir('template-catalog') do |root|
      @root = root
      @builtin = File.join(root, 'builtin')
      @custom = File.join(root, 'custom')
      FileUtils.mkdir_p([@builtin, @custom])
      example.run
    end
  end

  before do
    allow(described_class).to receive(:internal_template_location).and_return(@builtin)
    allow(described_class).to receive(:custom_template_location).and_return(@custom)
  end

  def template(root, name, config = 'category: misc')
    path = File.join(root, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'foobar.yml'), config) unless config.nil?
    path
  end

  it 'returns sorted, absolute-path hashes for builtin, custom and nested monorepo leaves only' do
    zebra = template(@builtin, 'template-Zebra')
    alpha = template(@custom, 'alpha', nil)
    container = template(@custom, 'platform', 'monorepo: true')
    nested = template(container, 'nested', 'monorepo: true')
    api = template(nested, 'template-api')
    template(container, 'docs', nil)
    template(container, '.git')
    template(@custom, '.hidden')
    template(@custom, 'empty-container', 'monorepo: true')
    File.write(File.join(@custom, 'ordinary-file'), 'not a template')

    expect(described_class.available_templates).to eq([
      { name: 'alpha', label: 'alpha', path: alpha, category: 'misc' },
      { name: 'api', label: 'api', path: api, category: 'misc' },
      { name: 'Zebra', label: 'Zebra', path: zebra, category: 'misc' }
    ])
  end

  it 'supports builtin monorepos and does not descend into ordinary template directories' do
    root = template(@builtin, 'collection', 'monorepo: true')
    leaf = template(root, 'leaf')
    template(leaf, 'not-another-template')
    expect(described_class.available_templates.map { |entry| entry[:path] }).to eq([leaf])
  end

  it 'disambiguates every duplicate with origin and root-relative path without losing source identity' do
    builtin = template(@builtin, 'template-api')
    custom = template(@custom, 'api')
    monorepo = template(@custom, 'z-platform', 'monorepo: true')
    leaf = template(monorepo, 'template-api')

    expect(described_class.available_templates).to eq([
      { name: 'api', label: 'api (builtin/template-api)', path: builtin, category: 'misc' },
      { name: 'api', label: 'api (custom/api)', path: custom, category: 'misc' },
      { name: 'api', label: 'api (custom/z-platform/template-api)', path: leaf, category: 'misc' }
    ])
    expect(described_class.available_templates).to eq(described_class.available_templates)
  end

  it 'sorts case-insensitively with deterministic source tie breaks' do
    template(@custom, 'template-API')
    template(@builtin, 'template-api')
    template(@custom, 'Beta')
    entries = described_class.available_templates
    expect(entries.map { |entry| entry[:name] }).to eq(%w[api API Beta])
    expect(entries.first(2).map { |entry| entry[:label] }).to eq(['api (builtin/template-api)', 'API (custom/template-API)'])
  end

  it 'does not change explicit builtin, direct custom, or monorepo resolution precedence' do
    builtin = template(@builtin, 'template-api')
    direct = template(@custom, 'api')
    root = template(@custom, 'platform', 'monorepo: true')
    leaf = template(root, 'template-api')
    # Legacy builtin presence checks use the gem directory directly.
    allow(described_class).to receive(:template_exists_within_repo?).with('api').and_return(true)
    expect(described_class.get_template_src(template: 'api')).to eq(builtin)
    allow(described_class).to receive(:template_exists_within_repo?).with('api').and_return(false)
    expect(described_class.get_template_src(template: 'api')).to eq(direct)
    FileUtils.rm_rf(direct)
    expect(described_class.get_template_src(template: 'api')).to eq(leaf)
  end

  it 'handles missing roots and missing or malformed metadata like legacy discovery' do
    FileUtils.rm_rf(@builtin)
    plain = template(@custom, 'plain', nil)
    malformed = template(@custom, 'malformed', 'invalid: [')
    expect(described_class.available_templates.map { |entry| entry[:path] }).to eq([malformed, plain])
    FileUtils.rm_rf(@custom)
    expect(described_class.available_templates).to eq([])
  end

  it 'excludes symlink templates, dangling links, linked containers, cycles, and linked metadata' do
    real = template(@custom, 'real')
    root = template(@custom, 'platform', 'monorepo: true')
    leaf = template(root, 'leaf')
    File.symlink(real, File.join(@custom, 'alias'))
    File.symlink('/does-not-exist', File.join(@custom, 'dangling'))
    File.symlink(root, File.join(@custom, 'container-alias'))
    File.symlink(root, File.join(root, 'cycle'))
    File.symlink(@custom, File.join(root, 'ancestor-cycle'))
    metadata_link = template(@custom, 'metadata-link', nil)
    File.symlink(File.join(real, 'foobar.yml'), File.join(metadata_link, 'foobar.yml'))
    expect(described_class.available_templates.map { |entry| entry[:path] }).to eq([leaf, real])
  end

  it 'does not follow a symlink catalog root' do
    template(@builtin, 'builtin')
    template(@custom, 'custom')
    linked = File.join(@root, 'linked-custom')
    File.symlink(@custom, linked)
    allow(described_class).to receive(:custom_template_location).and_return(linked)
    expect(described_class.available_templates.map { |entry| entry[:name] }).to eq(['builtin'])
  end

  it 'does not follow symlinks in ancestors of a configured root' do
    template(@custom, 'custom')
    linked_parent = File.join(@root, 'linked-parent')
    File.symlink(@root, linked_parent)
    allow(described_class).to receive(:custom_template_location).and_return(File.join(linked_parent, 'custom'))
    expect(described_class.available_templates).to eq([])
  end

  it 'deduplicates the same source directory when both roots coincide' do
    path = template(@builtin, 'one')
    allow(described_class).to receive(:custom_template_location).and_return(@builtin)
    expect(described_class.available_templates).to eq([{ name: 'one', label: 'one', path: path, category: 'misc' }])
  end

  it 'carries normalized leaf categories and sorts by category before template name' do
    template(@custom, 'aaa', 'category: services')
    root = template(@custom, 'collection', "monorepo: true\ncategory: ignored")
    template(root, 'zzz', 'category: PARTIAL')
    template(@custom, 'default', 'category: " "')

    expect(described_class.available_templates.map { |entry| [entry[:name], entry[:category]] })
      .to eq([['default', 'misc'], ['zzz', 'partial'], ['aaa', 'services']])
  end
end