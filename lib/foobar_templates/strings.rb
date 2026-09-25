module FoobarTemplates
  HELP_MSG = <<-HEREDOC
                    Foobar Templates version #{FoobarTemplates::VERSION}
Use foobar_templates to start a new project folder based on a predefined template.

Usage Examples:

  # Download all my template files (configured in ~/.foobar/config)
  $ foobar_templates --install-public-templates

  # Create a personal mono-repo template for your projects
  $ foobar_templates --setup-personal-templates

  # Create a ruby gem project using the built in service template
  $ foobar_templates --template ruby-cli-gem your_project_name

  # Merge templates into the current project (picker; no default template)
  $ foobar_templates merge
  $ foobar_templates merge -t ruby-cli-gem -s Gemfile
  $ foobar_templates merge --help

  # Convert the current directory which represents a working project into a
  # template by replacing project name variants with foo-bar placeholders
  $ cd my_recently_built_project
  $ foobar_templates --copy-to-templates
  HEREDOC

end
