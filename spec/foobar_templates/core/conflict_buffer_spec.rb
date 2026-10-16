require 'spec_helper'
require 'foobar_templates/core/conflict_buffer'

RSpec.describe FoobarTemplates::Core::ConflictBuffer do
  def build(local, incoming)
    described_class.build(local, incoming, local_label: 'local/a.rb', incoming_label: 'rendered/t/a.rb')
  end

  it 'wraps each changed region separately and keeps unchanged lines outside markers' do
    local = "one\ntwo\nthree\nfour\nfive\n"
    incoming = "one\nTWO\nthree\nfour\nFIVE\nsix\n"
    expect(build(local, incoming)).to eq(
      "one\n<<<<<<< local/a.rb\ntwo\n=======\nTWO\n>>>>>>> rendered/t/a.rb\nthree\nfour\n" \
      "<<<<<<< local/a.rb\nfive\n=======\nFIVE\nsix\n>>>>>>> rendered/t/a.rb\n"
    )
  end

  it 'represents pure additions and deletions with an empty side' do
    expect(build("a\nb\n", "a\n")).to eq("a\n<<<<<<< local/a.rb\nb\n=======\n>>>>>>> rendered/t/a.rb\n")
    expect(build('', "new\n")).to eq("<<<<<<< local/a.rb\n=======\nnew\n>>>>>>> rendered/t/a.rb\n")
  end

  it 'starts markers on their own line after an unterminated final line' do
    expect(build('same', "same\n")).to eq("<<<<<<< local/a.rb\nsame\n=======\nsame\n>>>>>>> rendered/t/a.rb\n")
  end

  it 'returns identical text unchanged' do
    expect(build("x\ny", "x\ny")).to eq("x\ny")
  end

  it 'detects only line-start conflict markers' do
    expect(described_class.unresolved?(build("a\n", "b\n"))).to be(true)
    expect(described_class.unresolved?("ok\n=======\n")).to be(true)
    expect(described_class.unresolved?("ok\r\n>>>>>>> theirs\r\n")).to be(true)
    expect(described_class.unresolved?("x <<<<<<< y\n========\n<<<<<<<<\n")).to be(false)
  end
end
