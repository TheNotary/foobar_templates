# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'foobar_templates/version'

version = FoobarTemplates::VERSION

Gem::Specification.new do |s|
  s.name          = "foobar_templates"
  s.version       = version
  s.authors       = ["TheNotary"]
  s.email         = ["no@mail.plz"]
  s.summary       = %q{This gem makes more gems!}
  s.description   = %q{ This is a gem for making more gems!  I know!  It's like asking a genie for more wishes but it actually works!}
  s.homepage      = "https://github.com/thenotary/foobar_templates"
  s.license       = "MIT"
  s.required_ruby_version = '>= 3.0'

  s.metadata["bug_tracker_uri"] = "https://github.com/TheNotary/foobar_templates/issues"
  s.metadata["changelog_uri"] = "https://github.com/TheNotary/foobar_templates/releases/tag/v#{version}"
  s.metadata["documentation_uri"] = "https://github.com/TheNotary/foobar_templates"
  s.metadata["source_code_uri"] = "https://github.com/TheNotary/foobar_templates/tree/v#{version}"

  # Include new implementation files in local builds before they are staged.
  s.files         = (`git ls-files -z`.split("\x0") + Dir.glob("lib/**/*.rb")).uniq
  s.executables   = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ["lib"]

  s.add_dependency "diff-lcs", "~> 1.6"
  s.add_dependency "unicode-display_width", "~> 2.6"

  s.add_development_dependency "rake", "~> 13.2"
  s.add_development_dependency "rdoc", "~> 7.0"
  s.add_development_dependency "rspec", "~> 3.13"
  s.add_development_dependency "pry", "~> 0.16"
end
