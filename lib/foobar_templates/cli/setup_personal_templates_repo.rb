module FoobarTemplates::CLI
  module SetupPersonalTemplatesRepo
    class << self

      def go(input: $stdin, output: $stdout)
        FoobarTemplates::validate_git_is_installed!
        configurator = FoobarTemplates::Configurator.new

        repo_domain = configurator.domain(:repo_domain)
        if repo_domain.nil? || repo_domain.to_s.strip.empty?
          output.puts "Error: `repo_domain` is not set in #{ENV['HOME']}/.foobar/config."
          output.puts "Please set it (e.g. `repo_domain: github.com`) and re-run."
          return
        end

        github_name = personal_templates_github_name(input: input, output: output).downcase
        return if github_name.nil? || github_name.empty?

        local_dir = "#{ENV['HOME']}/.foobar/templates/templates-#{github_name}"
        https_url = "https://#{repo_domain}/#{github_name}/templates-#{github_name}"
        ssh_url   = "git@#{repo_domain}:#{github_name}/templates-#{github_name}.git"

        if File.exist?(local_dir)
          output.puts "The template directory already exists, #{local_dir}"
          return
        end

        if remote_repo_exists?(https_url)
          output.print "You already have a templates directory available at #{https_url}, clone it down? [Y/n] "
          answer = (input.gets || "").strip.downcase
          if answer == "" || answer == "y" || answer == "yes"
            clone_personal_templates(local_dir, ssh_url, https_url, output: output)
          else
            output.puts "Aborted. No local directory was created."
          end
        else
          init_personal_templates_dir(local_dir, github_name, ssh_url, output: output)
        end
      end

      # Non-interactive resolver: returns the personal templates dir path based on
      # `git config --global user.name`, or nil if that is not set. Does not prompt.
      def personal_templates_dir
        name = `git config --global user.name`.to_s.strip.downcase
        return nil if name.empty?
        "#{ENV['HOME']}/.foobar/templates/templates-#{name}"
      end

      def personal_templates_github_name(input: $stdin, output: $stdout)
        name = `git config --global user.name`.to_s.strip
        return name unless name.empty?

        output.print "Enter your GitHub user name: "
        answer = (input.gets || "").strip
        if answer.empty?
          output.puts "Error: GitHub user name is required."
          return nil
        end
        answer
      end

      def remote_repo_exists?(url)
        cmd = %(curl -o /dev/null -s -w "%{http_code}" -L #{url})
        status = `#{cmd}`.to_s.strip
        return false if status == "404"
        # treat curl failure (empty status / non-numeric) as "exists" to avoid clobbering
        true
      end

      def clone_personal_templates(local_dir, ssh_url, https_url, output: $stdout)
        redirect = $test_env ? " 2> /dev/null" : ""
        ssh_cmd = "git clone #{ssh_url} #{local_dir}#{redirect}"
        `#{ssh_cmd}`
        if $?.success?
          output.puts "Cloned #{ssh_url} into #{local_dir}"
          return
        end

        https_cmd = "git clone #{https_url} #{local_dir}#{redirect}"
        `#{https_cmd}`
        if $?.success?
          output.puts "Cloned #{https_url} into #{local_dir}"
        else
          output.puts "Error: failed to clone from #{ssh_url} or #{https_url}."
        end
      end

      def init_personal_templates_dir(local_dir, github_name, ssh_url, output: $stdout)
        FileUtils.mkdir_p(local_dir)

        File.write("#{local_dir}/foobar.yml", "monorepo: true\n")
        File.write("#{local_dir}/README.md", personal_templates_readme(github_name))

        redirect = $test_env ? " > /dev/null 2>&1" : ""
        `cd #{local_dir} && git init#{redirect}`

        output.puts "Created personal templates mono-repo at #{local_dir}"
        output.puts "Next step: push it to your remote with:"
        output.puts "  cd #{local_dir} && git remote add origin #{ssh_url}"
      end

      def personal_templates_readme(github_name)
        <<~MARKDOWN
          # templates-#{github_name}

          This is a personal mono-repo of [foobar_templates](https://github.com/thenotary/foobar_templates)
          templates. It was scaffolded by `foobar_templates --setup-personal-templates`.

          ## Structure

          Each immediate child directory is a template. A child becomes a template when
          it contains its own `foobar.yml`. 

          ```
          templates-#{github_name}/
            foobar.yml              # monorepo: true
            README.md
            my-widget-template/
              foobar.yml            # category: frontend
              foo-bar.rb
            masm-project/
              foobar.yml            # category: low_level
              main.asm
          ```

          Run `foobar_templates --list` to see all templates discovered here, and
          `foobar_templates --template <name> my-project` to scaffold a new project from one.

          See https://github.com/thenotary/foobar_templates for full documentation.
        MARKDOWN
      end

    end
  end
end
