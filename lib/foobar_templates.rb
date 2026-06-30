require "foobar_templates/version"
require "foobar_templates/strings"
require 'foobar_templates/configurator'
require 'foobar_templates/template_manager'

require 'foobar_templates/core/core'
require 'foobar_templates/cli/cli'

require 'uri'

SOURCE_ROOT = File.expand_path("#{File.dirname(__FILE__)}/..")

module FoobarTemplates
  class CLIError < StandardError; end

  class << self

    def version
      FoobarTemplates::VERSION
    end

    def cheat_sheet
      CLI::CheatSheet.go
    end

    # lists available templates
    def list
      configurator = Configurator.new
      available_templates = configurator.collect_user_defined_templates

      available_templates = group_hashes_by_key(available_templates)
      output = convert_grouped_hashes_to_output(available_templates)

      if output.empty?
        empty_output_msg = "You have no templates.  You can install the public example templates with\n"
        empty_output_msg += "the below command:\n\n"
        empty_output_msg += "foobar_templates --install-public-templates"
        return empty_output_msg
      end

      mark_default_template(output, configurator.default_template)
    end

    def install_public_templates
      validate_git_is_installed!
      configurator = Configurator.new
      config_file_data = configurator.config_file_data
      puts "Downloading templates from the following locations: \n  #{config_file_data['public_templates'].split(" ").join("\n  ")}"
      config_file_data['public_templates'].split.each do |url|
        uri = URI.parse(url)
        template_folder_name = File.basename(uri.path).sub(/\.git$/, "")
        if !File.exist?("#{ENV['HOME']}/.foobar/templates/#{template_folder_name}")
          cmd = "cd #{ENV['HOME']}/.foobar/templates && git clone #{url}"
          cmd += " 2> /dev/null" if $test_env
          `#{cmd}`
        else
          puts "Warning: Skipping, template already exists #{ENV['HOME']}/.foobar/templates/#{template_folder_name}"
        end
      end
    end

    def validate_git_is_installed!
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "git#{ext}")
          return if File.executable?(exe) && !File.directory?(exe)
        end
      end

      raise CLIError, "Error: `git` command not found. Please install Git and ensure it's in your PATH."
    end

    def setup_personal_templates(input: $stdin, output: $stdout)
      CLI::SetupPersonalTemplatesRepo.go(input: input, output: output)
    end

    def dir_to_template(input: $stdin, output: $stdout)
      CLI::DirToTemplate.go(input: input, output: output)
    end

    def generate_template(options, gem_name)
      CLI::TemplateGenerator.new(options, gem_name).run
    rescue FoobarTemplates::CLIError => e
      msg = e.message
      $stderr.puts msg if msg && !msg.empty? && msg != e.class.name
    end

    # input:  [ { "predefined" => "default" },
    #           { "MISC" => "my_thing" },
    #           { "prdefined" => "service" }
    #         ]
    #
    # output: [ { "predefined" => ["default", "service"] },
    #           { "MISC" => ["my_thing"] }
    #         ]
    #
    def group_hashes_by_key(available_templates)
      h = {}
      available_templates.each do |hash|
        k = hash.first.first
        v = hash.first.last
        h[k] = [] unless h.has_key?(k)
        h[k] << v
      end
      h
    end

    # input:  [ { "predefined" => ["default", "service"] },
    #           { "MISC" => ["my_thing"] }
    #         ]
    def convert_grouped_hashes_to_output(available_templates)
      template_list_output = ""
      available_templates.each do |category, template_names|

        template_list_output << " #{category&.upcase || "UNSPECIFIED"}:\n"
        template_names.each do |el|
          template_list_output << "   #{el}\n"
        end
        template_list_output << "\n"
      end
      template_list_output
    end

    def mark_default_template(output_string, default_template)
      output_string.lines.reverse.map do |l|
        if l.strip == default_template
          l[1]= "*"
          "#{l.chomp}       (default)\n"
        else
          l
        end
      end.reverse.join
    end

    def which(executable)
      if File.file?(executable) && File.executable?(executable)
        executable
      elsif ENV['PATH']
        path = ENV['PATH'].split(File::PATH_SEPARATOR).find do |p|
          abs_path = File.join(p, executable)
          File.file?(abs_path) && File.executable?(abs_path)
        end
        path && File.expand_path(executable, path)
      end
    end

  end
end
