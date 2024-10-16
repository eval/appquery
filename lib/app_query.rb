# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"
require_relative "app_query/configuration"

module AppQuery
  class Error < StandardError; end

  class Configuration < Struct.new(:query_path, :adapter)
  end

  def self.configuration
    @configuration ||= AppQuery::Configuration.new
  end

  def self.configure
    yield configuration if block_given?
  end

  configure do |config|
    config.query_path = "app/queries"
    config.adapter = :active_record
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

    def tokens
      @tokens ||= tokenizer.run
    end

    def tokenizer
      @tokenizer ||= Tokenizer.new(to_s)
    end

    def cte_names
      tokens.filter { _1[:t] == "CTE_IDENTIFIER" }.map{ _1[:v] }
    end

    # query.prepend
    def prepend_cte
      if cte_names.none?
      else
      end
    end

    def select(sql = nil)
      if sql
        self.class.new(tokens.each_with_object([]) do |token, acc|
          v = token[:t] == "SELECT" ? sql : token[:v]
          acc << v
        end.join)
      else
        tokens.find { _1[:t] == "SELECT" }&.[](:v)
      end
    end

    def to_s
      @sql
    end
  end
end

def AppQuery(s)
  AppQuery::Q.new(s)
end
