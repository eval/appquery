require "yard"

YARD::Rake::YardocTask.new(:docs) do |t|
  # Options defined in `.yardopts` are read first, then merged with
  # options defined here.
  #
  # It's recommended to define options in `.yardopts` instead of here,
  # as `.yardopts` can be read by external YARD tools, like the
  # hot-reload YARD server `yard server --reload`.

  # Use APPQUERY_VERSION env var (set from git tag in CI), or fall back to git describe
  version = ENV["APPQUERY_VERSION"] || `git describe --tags --abbrev=0 2>/dev/null`.strip
  version = nil if version.empty?

  title = ["AppQuery", version, "API Documentation"].compact.join(" ")
  t.options += ["--title", title]
end
