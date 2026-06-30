# Foobar Templates: A Pain-Free Project Templator
[![Gem Version](https://badge.fury.io/rb/foobar_templates.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/foobar_templates)

Foobar Templates allow users to define project templates in the most native form to all technologist: Directory Structures, short commands, and helpful commands that make the tool's usage completely visible!

Programming often involves a lot of boilerplate and configuration "boot strapping" before you can get going actually writing any code.  To automate this aspect of creating new projects and microservices, foobar_templates allows you to run a simple command `foobar_templates -t my-c-embedded-template project-name` and it will clone a template you've made with exact specifications, update the names of files and references within the files to match your project name, run any commands specified in your template.  What once would have been a 5-10 minute distraction of remembering and implementing all those little patterns, testing dependencies, and pipeline definitions now happens immediately with a single command.

The most beneficial aspect of Foobar Templates is that it allows you to specify exactly how you want your 'default starting project' to look, rather than rely on what someone else thought would be generally helpful.

### Installation

I highly recommend the `foobar` alias!

```bash
gem install foobar_templates
foobar_templates --install-public-templates
foobar_templates --setup-personal-templates

echo "alias foobar='foobar_templates'" >> ~/.bashrc
source ~/.bashrc
```

#### List Available Templates

```bash
$  foobar_templates -l
PREDEFINED:
  default - A basic ruby gem
  service - A gem that allows installation as a service to run as a daemon

MISC:
  my_service -

EMBEDDED:
  arduino
```

### Usage

These commands will create a new gem named `project_name` in `/tmp/project_name`:

```bash
$  cd /tmp
$  foobar_templates -t arduino project_name
```

You'll find a project skeleton in ~/.foobar/templates/my_service that you can customize to your liking.

### Configuration

Configuration is stored in `~/.foobar/config` (created automatically on first run). At minimum, you need your git user name and email configured:

```bash
git config --global user.email your-public-gh@email.com
git config --global user.name YOUR_GH_NAME
```

## Create Your Own Template

> **WIP:** We're actively refactoring the template system. `constant_array` has been dropped and this may cause the ruby template to break. `unprefixed_name` and `unprefixed_pascal` have also been removed.

###### Overview
- Define the project as a working codebase using `foo-bar` as the project name
- All name variants (`foo_bar`, `FooBar`, `FOO_BAR`, etc.) will be auto-replaced when generating a new project
- Use `FOO_` prefixed placeholders for non-name variables (e.g., `FOO_AUTHOR`, `FOO_EMAIL`)
- Add a `foobar.yml` file to the template to make it available for use
- Run `foobar_templates --copy-to-templates` to convert an existing project's name variants into foo-bar placeholders
- Use the template to kick off a new project, `foobar_templates -t my-template first-test`

To create your own template, just create a new project using the technologies you'd like.  Place this project in `~/.foobar/templates/my-template`.  Once it's done, it's a good idea to create a git commit.  Then run something to the effect...

```bash
$  echo "category: frontend"    > foobar.yml
$  echo "purpose: frontend"    >> foobar.yml
$  echo "language: javascript" >> foobar.yml

$  foobar_templates --copy-to-templates
```

Change the foobar.yml contents to what makes sense for your template.  The `--copy-to-templates` command will prompt you for the template's folder name (defaults to the current project's basename) and the `category` to record in `foobar.yml` (defaults to the existing value, or `misc`), then replace all occurrences of your project's name variants with `foo-bar` template placeholders.

#### Categorizing Your Template

You can specify the `category` of the gem by editing the `foobar.yml` file in each template's root.  Categories are just used for organizing the output when you run `foobar_templates --list`.  Here's an [example](https://github.com/TheNotary/template-html-css-js/blob/main/foobar.yml).

#### Monorepo Template Collections

You can organize templates in nested directories by marking a directory as a monorepo container:

```yaml
monorepo: true
```

When a directory is marked with `monorepo: true`, Foobar Templates treats it as a container and recursively scans child directories for templates. A child is treated as a template when it has its own `foobar.yml` and is not marked `monorepo: true`.

Container-level files are ignored for generation. Only discovered leaf templates are selectable and usable with `foobar_templates`.

Example layout:

```text
~/.foobar/templates/template-platform/
  foobar.yml              # monorepo: true
  template-api/
    foobar.yml            # normal template config
    foo-bar.rb
  template-ui/
    foobar.yml            # normal template config
    foo-bar.rb
```

In this example, select templates by leaf name:

```bash
foobar_templates -t api my-service
foobar_templates -t ui my-frontend
```

If multiple monorepo leaves share the same name, Foobar Templates fails with an ambiguity error and shows the conflicting paths so one can be renamed.

#### Template Prefix Stripping

Some people sort their repos with prefixes...  For instance, you might want to create a repo named `tool-go-my-tool` but have the project file take on the name `my-tool` and ignore those descriptive prefixes?

You can do that!  Just setup your `foobar.yml` as below:
```yaml
purpose: tool
language: go
```

You can also set the prefix explicitly in `foobar.yml`:
```yaml
prefix: "my-custom-prefix-"
```

#### Customizing Your Own Templates

Place your own templates in `~/.foobar/templates`.  You can populate it with examples by running `foobar_templates --install-public-templates` which will effectively clone down a few sample git repos into the templates folder for you such as [Go-cli](https://github.com/TheNotary/template-go-cli) for instance.

You'll get a good idea as to the possibilities by inspecting the various templates I've opensourced under my github org, e.g. [template-ruby-cli-gem](https://github.com/TheNotary/template-ruby-cli-gem).

To pull up a list of available variables, run this command

```
$  foobar_templates --cheat-sheet
```

If you would find additional variables handy, set me up with a PR and assuming it seems widely helpful, I'll merge it right as soon as I can.   The implementation for the variables is largely found in [gem.rb](https://github.com/TheNotary/foobar_templates/blob/main/lib/foobar_templates/cli/template_generator.rb#L59).

#### Quick Tips Regarding Project Templates

- Templates are working code using `foo-bar` as the canonical project name
- Name variants (`foo_bar`, `FooBar`, `fooBar`, `FOO_BAR`, `Foo::Bar`, `Foo Bar`, `foo/bar`) are all auto-replaced
- Use `FOO_` prefixed placeholders for non-name variables: `FOO_AUTHOR`, `FOO_EMAIL`, `FOO_GIT_REPO_URL`, etc.
- Running `foobar_templates --cheat-sheet` will list off available template variables
- File **names** containing `foo-bar` or `foo_bar` will have those replaced by the project name


## Release Process

Cut a pre-release with:

```
rake release
```

Days or months later, promote it to a release:

```
git checkout OLD_RELEASE
rake promote
```

