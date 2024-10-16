# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"
require_relative "app_query/configuration"

module AppQuery
  class Error < StandardError; end

  def self.configuration
    @configuration ||= AppQuery::Configuration.new
  end

  def self.configure
    yield configuration if block_given?
  end

  def self.[](v)
    Q.new((Pathname.new(configuration.query_path) / "#{v}.sql").expand_path.read)
  end

  class Q
    def initialize(sql)
      @sql = sql
    end

    def select_all(binds = [])
      ActiveRecord::Base.connection.select_all(to_s, nil, binds)
    end

    def as_cte(name = "result", select: "SELECT * FROM result")
      self.class.new(<<~SQL)
      WITH #{name.inspect} AS (
        #{@sql}
      )
      #{select}
      SQL
    end

    def to_s
      @sql
    end
  end
end

def AppQuery(s)
  AppQuery::Q.new(s)
end
