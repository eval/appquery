# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"
require "active_record"

module AppQuery
  class Error < StandardError; end

  Configuration = Struct.new(:query_path)

  def self.configuration
    @configuration ||= AppQuery::Configuration.new
  end

  def self.configure
    yield configuration if block_given?
  end

  def self.reset_configuration!
    configure do |config|
      config.query_path = "app/queries"
    end
  end
  reset_configuration!

  def self.[](v)
    query_name = v.to_s
    full_path = (Pathname.new(configuration.query_path) / "#{query_name}.sql").expand_path
    Q.new(full_path.read, name: "AppQuery #{query_name}")
  end

  class Result < ActiveRecord::Result
    attr_accessor :cast
    alias_method :cast?, :cast

    def initialize(columns, rows, overrides = nil, cast: false)
      super(columns, rows, overrides)
      @cast = cast
      # Rails v6.1: prevent mutate on frozen object on #first
      @hash_rows = [] if columns.empty?
    end

    def column(name = nil)
      return [] if empty?
      unless name.nil? || includes_column?(name)
        raise ArgumentError, "Unknown column #{name.inspect}. Should be one of #{columns.inspect}."
      end
      ix = name.nil? ? 0 : columns.index(name)
      rows.map { _1[ix] }
    end

    def self.from_ar_result(r, cast = nil)
      if r.empty?
        EMPTY
      else
        cast &&= case cast
                 when Array
                   r.columns.zip(cast).to_h
                 when Hash
                   cast
                 else
                   {}
                 end
        if !cast || (cast.empty? && r.column_types.empty?)
          # nothing to cast
          new(r.columns, r.rows, r.column_types)
        else
          overrides = (r.column_types || {}).merge(cast)
          rows = r.columns.one? ? [r.cast_values(overrides)] : r.cast_values(overrides)
          new(r.columns, rows, overrides, cast: true)
        end
      end
    end

    empty_array = [].freeze
    EMPTY_HASH = {}.freeze
    private_constant :EMPTY_HASH

    EMPTY = new(empty_array, empty_array, EMPTY_HASH).freeze
    private_constant :EMPTY
  end

  class Q
    attr_reader :name, :sql

    def initialize(sql, name: nil)
      @sql = sql
      @name = name
    end

    def select_all(binds: [], select: nil, qselect: nil, cast: false)
      with(select:, qselect:).then do |aq|
        ActiveRecord::Base.connection.select_all(aq.to_s, name, binds).then do |result|
          Result.from_ar_result(result, cast)
        end
      end
    end

    def select_one(binds: [], select: nil, qselect: nil, cast: false)
      select_all(binds:, select:, qselect:, cast:).first || {}
    end

    def select_value(binds: [], select: nil, qselect: nil, cast: false)
      select_one(binds:, select:, qselect:, cast:).values.first
    end

    def with(select: nil, qselect: nil)
      self.then { select ? _1.with_select(select) : _1 }.then do |aq|
        qselect ? aq.with_qselect(qselect) : aq
      end
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

    def with_select(sql)
      self.class.new(tokens.each_with_object([]) do |token, acc|
        v = token[:t] == "SELECT" ? sql : token[:v]
        acc << v
      end.join, name: name)
    end

    # query select, i.e. select from the end result of the query.
    # Example
    # AppQuery("select * from (VALUES(1,'Some article'), (2, 'Another article')) dummy")
    def with_qselect(s)
      self.class.new(<<~SQL, name: name)
      WITH "result" AS (
      #{indent(@sql, 2)}
      )
      #{s}
      SQL
    end

    def select
      tokens.find { _1[:t] == "SELECT" }&.[](:v)
    end

    def recursive?
      !!tokens.find { _1[:t] == "RECURSIVE" }
    end

    # example:
    #  AppQuery("select 1").prepend_cte("foo as(select 1)")
    def prepend_cte(cte)
      # early raise when cte is not valid sql
      to_append = Tokenizer.tokenize(cte, state: :lex_prepend_cte).then do |tokens|
        recursive? ? tokens.reject { _1[:t] == "RECURSIVE" } : tokens
      end 

      if cte_names.none?
        self.class.new("WITH #{cte}\n#{self}")
      else
        split_at_type = recursive? ? "RECURSIVE" : "WITH"
        self.class.new(tokens.map do |token|
          if token[:t] == split_at_type
            token[:v] + to_append.map { _1[:v] }.join
          else
            token[:v]
          end
        end.join)
      end
    end

    # example:
    #  AppQuery("select 1").append_cte("foo as(select 1)")
    def append_cte(cte)
      # early raise when cte is not valid sql
      add_recursive, to_append = Tokenizer.tokenize(cte, state: :lex_append_cte).then do |tokens|
        [!recursive? && tokens.find { _1[:t] == "RECURSIVE" },
         tokens.reject { _1[:t] == "RECURSIVE" }]
      end

      if cte_names.none?
        self.class.new("WITH #{cte}\n#{self}")
      else
        nof_ctes = cte_names.size

        self.class.new(tokens.map do |token|
          nof_ctes -= 1 if token[:t] == "CTE_SELECT"

          if nof_ctes.zero?
            nof_ctes -= 1
            token[:v] + to_append.map { _1[:v] }.join
          elsif token[:t] == "WITH" && add_recursive
            token[:v] + add_recursive[:v]
          else
            token[:v]
          end
        end.join)
      end
    end

    # Replaces an existing cte with the same name.
    # Does nothing if cte does not exist.
    def replace_cte(cte)
      add_recursive, to_append = Tokenizer.tokenize(cte, state: :lex_recursive_cte).then do |tokens|
        [!recursive? && tokens.find { _1[:t] == "RECURSIVE" },
         tokens.reject { _1[:t] == "RECURSIVE" }]
      end

      cte_name = to_append.find { _1[:t] == "CTE_IDENTIFIER" }&.[](:v)
      cte_ix = cte_names.index(cte_name)

      return self unless cte_ix

      cte_found = false

      self.class.new(tokens.map do |token|
        if (cte_found ||= (token[:t] == "CTE_IDENTIFIER" && token[:v] == cte_name))
          unless (cte_found = (token[:t] != "CTE_SELECT"))
            next to_append.map { _1[:v] }.join
          end

          next
        elsif token[:t] == "WITH" && add_recursive
          token[:v] + add_recursive[:v]
        else
          token[:v]
        end
      end.join)
    end

    def to_s
      @sql
    end

    private

    # Copied from Rails
    def indent(s, amount)
      indent_string = s[/^[ \t]/] || " "
      s.gsub(/^(?!$)/, indent_string * amount)
    end
  end
end

def AppQuery(s)
  AppQuery::Q.new(s)
end

begin
  require "rspec"
rescue LoadError
end

require_relative "app_query/rspec" if Object.const_defined? "RSpec"
