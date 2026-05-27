# frozen_string_literal: true

require "active_support/concern"

module AppQuery
  # Middleware concern that maps query results to Ruby objects in {BaseQuery} subclasses.
  #
  # Include this module to automatically convert result hashes into typed objects
  # like +Data+ classes or +Struct+s.
  #
  # By default, looks for an +Item+ constant in the query class.
  # Use +map_to+ to specify a different class.
  #
  # @note This is a {BaseQuery} middleware. Include it in classes that inherit
  #   from {BaseQuery} to transform hash results into typed objects.
  #
  # @see BaseQuery Base class for query objects
  # @see Paginatable Another middleware for pagination support
  #
  # @example With default Item class
  #   class ArticlesQuery < ApplicationQuery
  #     include AppQuery::Mappable
  #
  #     class Item < Data.define(:title, :url, :published_on)
  #     end
  #   end
  #
  #   articles = ArticlesQuery.new.entries
  #   articles.first.title  # => "Hello World"
  #
  # @example With explicit map_to
  #   class ArticlesQuery < ApplicationQuery
  #     include AppQuery::Mappable
  #     map_to :article
  #
  #     class Article < Data.define(:title, :url)
  #     end
  #   end
  #
  # @example Skip mapping with raw
  #   articles = ArticlesQuery.new.raw.entries
  #   articles.first  # => {"title" => "Hello", "url" => "..."}
  #
  # @example Combining with Paginatable
  #   class ArticlesQuery < ApplicationQuery
  #     include AppQuery::Paginatable
  #     include AppQuery::Mappable
  #
  #     class Item < Data.define(:title, :url)
  #     end
  #   end
  #
  #   # Results are paginated AND mapped to Item objects
  #   ArticlesQuery.new.paginate(page: 1).entries.first.title
  module Mappable
    extend ActiveSupport::Concern

    class_methods do
      def map_to(name = nil)
        name ? @map_to = name : @map_to
      end
    end

    def raw
      @raw = true
      self
    end

    # Append our transform to the underlying Q's RowBuilder pipeline so every
    # row-returning path (entries, first, last, take, with_select(...).first,
    # …) sees mapped rows. Stacks with other row-level middlewares in
    # include-order — earlier `include`s run first.
    def query
      @query ||= super.tap { |q| q.row_builder << method(:build_row) }
    end

    private

    def build_row(row)
      return row if @raw
      return row unless (klass = resolve_map_klass)
      klass.new(**row.symbolize_keys.slice(*klass.members))
    end

    def resolve_map_klass
      case (name = self.class.map_to)
      when Symbol
        self.class.const_get(name.to_s.classify)
      when Class
        name
      when nil
        self.class.const_get(:Item) if self.class.const_defined?(:Item)
      end
    end
  end
end
