require 'spec_helper'
require 'tmpdir'
require 'foobar_templates/core/template_renderer'

RSpec.describe FoobarTemplates::Core::TemplateRenderer do
  let(:config) do
    {
      name: 'good-dog', screamcase_name: 'GOOD_DOG', pascal_name: 'GoodDog',
      camel_name: 'goodDog', underscored_name: 'good_dog', title: 'Good Dog',
      namespaced_path: 'good/dog', constant_name: 'Good::Dog',
      registry_repo_path: 'registry.example/test/good-dog', git_repo_domain: 'github.com',
      git_repo_path: 'github.com/test/good-dog', git_repo_url: 'https://github.com/Test/good-dog',
      registry_domain: 'registry.example', image_path: 'test/good-dog',
      k8s_domain: 'cluster.example', author: 'Test', email: 'test@example.com',
    }
  end
  subject(:renderer) { described_class.new(config) }

  around do |example|
    Dir.mktmpdir('template-renderer') do |dir|
      @source = File.join(dir, 'source')
      example.run
    end
  end

  def render(bytes)
    File.binwrite(@source, bytes)
    renderer.render_file(@source)
  end

  it 'renders only the five filename variants in paths' do
    expect(renderer.render_path('FOO_BAR/FooBar/fooBar/foo-bar/foo_bar/Foo::Bar/Foo Bar/foo/bar'))
      .to eq('GOOD_DOG/GoodDog/goodDog/good-dog/good_dog/Foo::Bar/Foo Bar/foo/bar')
  end

  it 'renders every content variant and composite placeholder as bytes' do
    text = 'FOO_REGISTRY_REPO_PATH FOO_GIT_REPO_DOMAIN FOO_GIT_REPO_PATH FOO_GIT_REPO_URL FOO_REGISTRY_DOMAIN FOO_IMAGE_PATH FOO_K8S_DOMAIN FOO_AUTHOR FOO_EMAIL Foo::Bar FOO_BAR FooBar fooBar Foo Bar foo/bar foo-bar foo_bar'
    expected = 'registry.example/test/good-dog github.com github.com/test/good-dog https://github.com/Test/good-dog registry.example test/good-dog cluster.example Test test@example.com Good::Dog GOOD_DOG GoodDog goodDog Good Dog good/dog good-dog good_dog'
    result = render(text)
    expect(result).to eq(expected.b)
    expect(result.encoding).to eq(Encoding::BINARY)
    expect(File.binread(@source)).to eq(text)
  end

  it 'preserves sequential replacement order within inserted values' do
    config[:author] = 'FooBar foo-bar'
    config[:registry_repo_path] = 'FOO_GIT_REPO_DOMAIN/foo-bar'
    expect(render('FOO_AUTHOR FOO_REGISTRY_REPO_PATH')).to eq('GoodDog good-dog github.com/good-dog')
  end

  it 'escapes exactly the next non-whitespace token after >>>, including punctuation' do
    expect(render(">>> foo-bar >>> FOO_GIT_REPO_URL, foo-bar\n>>>\tFoo::Bar >>> Foo Bar"))
      .to eq("foo-bar FOO_GIT_REPO_URL, good-dog\nFoo::Bar Foo Bar")
  end

  it 'does not treat >>> without following whitespace as an escape' do
    expect(render('>>>foo-bar >>>')).to eq('>>>good-dog >>>')
  end

  it 'keeps bootstrap string replacement unescaped' do
    expect(renderer.render_string('>>> foo-bar')).to eq('>>> good-dog')
  end

  it 'passes null-containing binary files through unchanged' do
    bytes = "\x00foo-bar >>> FooBar\xff".b
    expect(render(bytes)).to eq(bytes)
  end

  it 'preserves binaries whose first NUL occurs after 8 KiB' do
    bytes = ('foo-bar ' * 2000).b + "\0>>> FooBar".b
    expect(render(bytes)).to eq(bytes)
  end

  it 'passes invalid UTF-8 through unchanged, even beyond the initial binary probe' do
    bytes = ('foo-bar ' * 2000).b + "\xff".b
    expect(render(bytes)).to eq(bytes)
  end

  it 'retains UTF-8 text, CRLF, and a missing trailing newline' do
    expect(render("café foo-bar\r\n雪 FooBar")).to eq("café good-dog\r\n雪 GoodDog".b)
  end

  it 'supports empty files and absent optional domains' do
    config[:registry_repo_path] = config[:registry_domain] = config[:k8s_domain] = nil
    expect(render('')).to eq(''.b)
    expect(render('FOO_REGISTRY_DOMAIN|FOO_K8S_DOMAIN|FOO_REGISTRY_REPO_PATH')).to eq('||')
  end
end