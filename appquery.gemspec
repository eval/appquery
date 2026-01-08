# frozen_string_literal: true

require_relative "lib/app_query/version"

Gem::Specification.new do |spec|
  spec.name = "appquery"
  spec.version = AppQuery::VERSION
  spec.authors = ["Gert Goet"]
  spec.email = ["gert@thinkcreate.dk"]

  spec.summary = "raw SQL 🥦, cooked 🍲 or: make working with raw SQL queries in Rails convenient by improving their introspection and testability."
  spec.description = <<~DESC
    Improving introspection and testability of raw SQL queries in Rails
    This gem improves introspection and testability of raw SQL queries in Rails by:
    - ...providing a separate query-folder and easy instantiation  
      A query like `AppQuery[:some_query]` is read from app/queries/some_query.sql.

    - ...providing options for rewriting a query:

      Query a CTE by replacing the select:
      query.select_all(select: "select * from some_cte").entries

      ...similarly, query the end result (i.e. CTE `_`):
      query.select_all(select: "select count(*) from _").entries

    - ...providing (custom) casting:  
      AppQuery("select array[1,2]").select_value(cast: true)

      custom deserializers:
      AppQuery("select '1' id").select_all(cast: {"id" => ActiveRecord::Type::Integer.new}).entries

    - ...providing spec-helpers and generators
  DESC
  spec.homepage = "https://github.com/eval/appquery"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/eval/appquery"
  spec.metadata["changelog_uri"] = "https://github.com/eval/appquery/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ examples/ .git .github appveyor Gemfile gemfiles/ tmp/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  spec.add_development_dependency "appraisal"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
