# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"

module AppQuery
  class Error < StandardError; end

  Configuration = Struct.new(:query_path, :adapter)

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
    query_name = v.to_s
    full_path = (Pathname.new(configuration.query_path) / "#{query_name}.sql").expand_path
    Q.new(full_path.read, name: "AppQuery #{query_name}")
  end

  class Q
    attr_reader :name

    def initialize(sql, name: nil)
      @sql = sql
      @name = name
    end

    def select_all(binds = [])
      ActiveRecord::Base.connection.select_all(to_s, name, binds)
    end

    def select_one(binds = [])
      ActiveRecord::Base.connection.select_one(to_s, name, binds)
    end

    def as_cte(name = "result", select: "SELECT * FROM result")
      self.class.new(<<~SQL, name: name)
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
        end.join, name: name)
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
