# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"

module AppQuery
  class Error < StandardError; end

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

  class << self
    def [](k)
    end
  end
end

def AppQuery(s)
  AppQuery::Q.new(s)
end
