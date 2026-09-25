module FoobarTemplates
  module Core
    # Pure rendering: no destination writes, configuration prompts or lifecycle.
    class TemplateRenderer
      def initialize(config)
        @config = config
      end

      def render_path(relative_path)
        replace(relative_path, filename_replacement_pairs)
      end

      # Always return bytes, including for UTF-8 text. Invalid UTF-8 and binary
      # files are opaque and must never enter the text substitution pipeline.
      def render_file(absolute_source)
        bytes = File.binread(absolute_source)
        return bytes if self.class.binary_content?(bytes)

        render_string(bytes.force_encoding(Encoding::UTF_8), escape: true).b
      end

      def self.binary_content?(bytes)
        bytes.include?("\x00") ||
          !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end

      def binary_file?(path)
        self.class.binary_content?(File.binread(path))
      end

      # Bootstrap strings historically do not use the file-only >>> escape.
      def render_string(content, escape: false)
        content = content.gsub(/>>>\s+(\S+)/) { $1.chars.join("\x00") } if escape
        content = replace(content, content_replacement_pairs)
        escape ? content.gsub("\x00", '') : content
      end

      def filename_replacement_pairs
        [
          ['FOO_BAR', @config[:screamcase_name]],
          ['FooBar', @config[:pascal_name]],
          ['fooBar', @config[:camel_name]],
          ['foo-bar', @config[:name]],
          ['foo_bar', @config[:underscored_name]],
        ]
      end

      def content_replacement_pairs
        [
          ['FOO_REGISTRY_REPO_PATH', @config[:registry_repo_path] || ''],
          ['FOO_GIT_REPO_DOMAIN', @config[:git_repo_domain]],
          ['FOO_GIT_REPO_PATH', @config[:git_repo_path]],
          ['FOO_GIT_REPO_URL', @config[:git_repo_url]],
          ['FOO_REGISTRY_DOMAIN', @config[:registry_domain] || ''],
          ['FOO_IMAGE_PATH', @config[:image_path]],
          ['FOO_K8S_DOMAIN', @config[:k8s_domain] || ''],
          ['FOO_AUTHOR', @config[:author]],
          ['FOO_EMAIL', @config[:email]],
          ['Foo::Bar', @config[:constant_name]],
          ['FOO_BAR', @config[:screamcase_name]],
          ['FooBar', @config[:pascal_name]],
          ['fooBar', @config[:camel_name]],
          ['Foo Bar', @config[:title]],
          ['foo/bar', @config[:namespaced_path]],
          ['foo-bar', @config[:name]],
          ['foo_bar', @config[:underscored_name]],
        ]
      end

      private

      def replace(content, pairs)
        pairs.inject(content) { |result, (find, replacement)| result.gsub(find, replacement) }
      end
    end
  end
end