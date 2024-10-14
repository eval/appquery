# frozen_string_literal: true

require_relative "lib/app_query/version"

Gem::Specification.new do |spec|
  spec.name = "appquery"
  spec.version = AppQuery::VERSION
  spec.authors = ["Gert Goet"]
  spec.email = ["gert@thinkcreate.dk"]

  spec.summary = "Make working with raw SQL queries convenient by improving their introspection and testability."
  spec.description = <<~DESC
    A query like `AppQuery[:some_query]` is read from app/queries/some_query.sql.

    Querying a CTE used in this query:
    `query.replace_select("select * from some_cte").select_all`

    Query the end-result:
    `query.as_cte(select: "select COUNT(*) from app_query").select_all`

    Spec-helpers and generators included.
DESC
  spec.homepage = "https://github.com/eval/appquery"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/eval/appquery"
  spec.metadata["changelog_uri"] = "https://github.com/eval/gem-try/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
