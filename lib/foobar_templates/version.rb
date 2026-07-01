VERSION = "2.0.1.rc5"

module FoobarTemplates
  VERSION = ENV.fetch("GEM_VERSION", VERSION)
end
