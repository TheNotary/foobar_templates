VERSION = "2.0.2.rc1"

module FoobarTemplates
  VERSION = ENV.fetch("GEM_VERSION", VERSION)
end
