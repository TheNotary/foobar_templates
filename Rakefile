require 'rake'
require 'rubygems'
require 'rspec/core/rake_task'

GEM_NAME = "foobar_templates"
GEM_SPEC = "#{GEM_NAME}.gemspec"
VERSION_FILE = "lib/#{GEM_NAME}/version.rb"

module ReleaseHelper
  module_function

  # Prerelease syntax: `MAJOR.MINOR.PATCH.rcN` (e.g. `2.0.1.rc1`).
  # Gem apparently doesn't support semver's `-` syntax =/
  RC_RE = /\A(\d+)\.(\d+)\.(\d+)\.rc(\d+)\z/
  REL_RE = /\A(\d+)\.(\d+)\.(\d+)\z/

  def dry_run?
    ENV['RELEASE_DRY_RUN'] == '1'
  end

  def current_version
    return ENV['GEM_VERSION'] if ENV['GEM_VERSION']

    src = File.read(VERSION_FILE)
    m = src.match(/VERSION\s*=\s*["']([^"']+)["']/)
    abort "Could not parse VERSION from #{VERSION_FILE}" unless m
    m[1]
  end

  def strip_rc(version)
    m = version.match(RC_RE)
    return nil unless m
    maj, min, pat, _rc = m.captures
    "#{maj}.#{min}.#{pat}"
  end

  def rc_tag_on_head
    tags = `git tag --points-at HEAD`.strip.split("\n")
    tags.find { |t| t.match?(/\Av\d+\.\d+\.\d+\.rc\d+\z/) }
  end

  def next_version(v)
    if (m = v.match(RC_RE))
      maj, min, pat, rc = m.captures.map(&:to_i)
      "#{maj}.#{min}.#{pat}.rc#{rc + 1}"
    elsif (m = v.match(REL_RE))
      maj, min, pat = m.captures.map(&:to_i)
      "#{maj}.#{min}.#{pat + 1}.rc1"
    else
      abort "Unrecognized version format: #{v.inspect} (expected MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH.rcN)"
    end
  end

  def write_version!(new_version)
    src = File.read(VERSION_FILE)
    updated = src.sub(/VERSION\s*=\s*"[^"]+"/, %(VERSION = "#{new_version}"))
    File.write(VERSION_FILE, updated)
  end

  def confirm!(prompt, default: false)
    suffix = default ? "[Y/n]" : "[y/N]"
    print "#{prompt} #{suffix} "
    answer = $stdin.gets&.strip
    return default if answer.nil? || answer.empty?
    %w[y yes].include?(answer.downcase)
  end

  def sh!(cmd)
    puts "+ #{cmd}"
    abort "command failed: #{cmd}" unless system(cmd)
  end

  def push!(cmd)
    if dry_run?
      puts "[DRY-RUN] would run: #{cmd}"
    else
      sh!(cmd)
    end
  end

  def ensure_clean_git!
    out = `git status --porcelain`
    return if out.strip.empty?
    abort "Working tree is dirty. Commit or stash changes before releasing.\n#{out}"
  end

  def ensure_on_default_branch!
    branch = `git rev-parse --abbrev-ref HEAD`.strip
    return if %w[main master].include?(branch)
    return if confirm!("You are on branch '#{branch}', not main/master. Continue?", default: false)
    abort "Aborted by user."
  end

  def working_tree_changed?
    !`git status --porcelain`.strip.empty?
  end

  # Make sure this machine has push access to the gem repository
  def preflight!
    problems = []

    cred_paths = [
      File.expand_path("~/.gem/credentials"),
      File.expand_path("~/.local/share/gem/credentials"),
    ]
    cred_path = cred_paths.find { |p| File.exist?(p) }
    if cred_path.nil?
      problems << "No rubygems credentials found (looked in #{cred_paths.join(', ')}). Run `gem signin`."
    elsif (File.stat(cred_path).mode & 0o077) != 0
      problems << "Rubygems credentials at #{cred_path} are world/group-readable. Run: chmod 0600 #{cred_path}"
    end

    unless problems.empty?
      abort "Release preflight failed:\n  - #{problems.join("\n  - ")}"
    end

    puts "Checking rubygems push access for #{GEM_NAME}..."
    owners_out = `gem owner #{GEM_NAME} </dev/null 2>&1`
    unless $?.success?
      abort "Cannot query rubygems owners for #{GEM_NAME}:\n#{owners_out}\nRun `gem signin` and ensure your API key has push scope."
    end
  end
end

desc "Build #{GEM_NAME} gem"
task :build do
  FileUtils.mkdir_p "pkg"
  FileUtils.rm_f Dir.glob("pkg/#{GEM_NAME}-*.gem")
  FileUtils.rm_f Dir.glob("#{GEM_NAME}-*.gem")
  system "gem build #{GEM_SPEC}"
  FileUtils.mv Dir.glob("#{GEM_NAME}-*.gem"), "pkg/"
end

desc "Install #{GEM_NAME} gem locally"
task install: :build do
  system "gem install pkg/#{Dir.children('pkg').sort.last}"
end

desc "Interactive local release: confirm version, run specs, build, tag, push, and bump"
task :release do
  include_helper = ReleaseHelper

  include_helper.ensure_clean_git!
  include_helper.ensure_on_default_branch!
  include_helper.preflight!

  version = include_helper.current_version
  puts "Current version in #{VERSION_FILE}: #{version}"
  unless include_helper.confirm!("Release version #{version}?", default: false)
    puts "Aborted. Edit #{VERSION_FILE} to change the version, then re-run `rake release`."
    exit 0
  end

  Rake::Task[:spec].invoke
  Rake::Task[:build].invoke

  gem_file = "pkg/#{GEM_NAME}-#{version}.gem"
  abort "Built gem not found at #{gem_file}" unless File.exist?(gem_file)

  if include_helper.working_tree_changed?
    include_helper.sh! "git add #{VERSION_FILE}"
    include_helper.sh! %(git commit -m "Release v#{version}")
  end

  tag = "v#{version}"
  include_helper.sh! %(git tag -a #{tag} -m "Release #{tag}")
  include_helper.push! "git push origin HEAD"
  include_helper.push! "git push origin #{tag}"
  include_helper.push! "gem push #{gem_file}"

  next_v = include_helper.next_version(version)
  include_helper.write_version!(next_v)
  include_helper.sh! "git add #{VERSION_FILE}"
  include_helper.sh! %(git commit -m "Bump to v#{next_v}")
  include_helper.push! "git push origin HEAD"

  puts ""
  puts "=" * 60
  puts "Released: #{tag}"
  puts "Next development version: #{next_v}"
  puts "Tag: https://github.com/TheNotary/#{GEM_NAME}/releases/tag/#{tag}"
  puts "=" * 60
end

desc "Promote a pre-release commit to a final release (no new commit needed)"
task :promote, [:version] do |_t, args|
  include_helper = ReleaseHelper

  include_helper.preflight!

  # Determine the RC tag on HEAD
  rc_tag = include_helper.rc_tag_on_head
  abort "No pre-release tag (vX.Y.Z.rcN) found on HEAD. Checkout a tagged RC commit first." unless rc_tag
  rc_version = rc_tag.sub(/\Av/, '')

  # Determine target release version
  release_version = args[:version] || include_helper.strip_rc(rc_version)
  abort "Could not derive release version from #{rc_version}" unless release_version
  abort "Target version #{release_version} is not a release format (expected MAJOR.MINOR.PATCH)" unless release_version.match?(ReleaseHelper::REL_RE)

  sha = `git rev-parse --short HEAD`.strip
  puts "Promoting commit #{sha} (tagged #{rc_tag}) \u2192 v#{release_version}"
  unless include_helper.confirm!("Continue?", default: false)
    puts "Aborted."
    exit 0
  end

  # Build gem with the release version (override via ENV, no file edit)
  ENV['GEM_VERSION'] = release_version
  Rake::Task[:build].invoke

  gem_file = "pkg/#{GEM_NAME}-#{release_version}.gem"
  abort "Built gem not found at #{gem_file}" unless File.exist?(gem_file)

  # Tag and push
  tag = "v#{release_version}"
  include_helper.sh! %(git tag -a #{tag} -m "Release #{tag}")
  include_helper.push! "git push origin #{tag}"
  include_helper.push! "gem push #{gem_file}"

  puts ""
  puts "=" * 60
  puts "Promoted: #{rc_tag} \u2192 #{tag}"
  puts "Tag: https://github.com/TheNotary/#{GEM_NAME}/releases/tag/#{tag}"
  puts "=" * 60
end

desc "Run unit specs"
RSpec::Core::RakeTask.new(:unit) do |t|
  t.rspec_opts = %w(-fd -c)
  t.pattern = "./spec/unit/**/*_spec.rb"
end

desc "Run integration specs that are very high level"
RSpec::Core::RakeTask.new(:integration) do |t|
  t.rspec_opts = %w(-fd -c)
  t.pattern = "./spec/integration/**/*_spec.rb"
end

desc "Run all specs"
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = %w(-fd -c)
end

# this is for running tests that you've marked current... eg: it 'should work', current:  true do
RSpec::Core::RakeTask.new(:current) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rspec_opts = ['--tag current']
end

# alias for current
RSpec::Core::RakeTask.new(:c) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rspec_opts = ['--tag current']
end

task default:  :spec
task test:  :spec
